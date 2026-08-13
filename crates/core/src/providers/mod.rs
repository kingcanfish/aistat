pub mod flashduty;
pub mod icon;
pub mod statuspage;

use std::time::Duration;

use serde::de::DeserializeOwned;

use crate::config::{AdapterKind, SiteConfig};
use crate::model::SiteStatus;

/// The HTTP client type, re-exported so callers can hold one without taking a
/// direct dependency on our `reqwest` version.
pub use reqwest::Client as HttpClient;

const TIMEOUT: Duration = Duration::from_secs(15);
const USER_AGENT: &str = concat!("aistat/", env!("CARGO_PKG_VERSION"));

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("parse error: {0}")]
    Parse(String),
    #[error("stale data: {0}")]
    Stale(String),
    #[error("{0}")]
    Message(String),
}

/// Builds the shared HTTP client.
///
/// Build this **once** and reuse it: reqwest pools connections and reuses TLS
/// sessions per client, which halves a warm refresh (measured ~600ms → ~300ms
/// across three sites). A client per refresh throws that away.
pub fn build_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .user_agent(USER_AGENT)
        .pool_idle_timeout(Duration::from_secs(300))
        .build()
        .unwrap_or_default()
}

/// Hosts whose TLS handshake Rust's stacks can't complete, so we go straight to
/// the `curl` fallback instead of paying for a request that always fails.
///
/// A per-process memo only: skipping it merely costs the failed attempt again
/// (~67ms), so a cold cache is never wrong, just slower.
fn curl_only_hosts() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static HOSTS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    HOSTS.get_or_init(Default::default)
}

fn host_of(url: &str) -> String {
    url.split("://")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .unwrap_or(url)
        .to_string()
}

/// GETs `url` and deserializes the JSON body.
///
/// Some status pages sit behind middleboxes that reject the TLS ClientHello
/// sent by Rust's TLS stacks (both rustls and the macOS Security.framework
/// backend) while accepting OpenSSL's — `status.deepseek.com` is one. When the
/// request fails before any HTTP response is seen, retry once through the
/// system `curl`, which ships on macOS, Linux and Windows 10+ and uses a TLS
/// profile those middleboxes accept.
pub async fn fetch_text(client: &reqwest::Client, url: &str) -> Result<String, ProviderError> {
    let host = host_of(url);
    if curl_only_hosts().lock().unwrap().contains(&host) {
        return curl_get(url).await;
    }

    let response = match client.get(url).send().await {
        Ok(r) => Some(r.error_for_status()?),
        Err(e) if is_connection_error(&e) => None,
        Err(e) => return Err(e.into()),
    };

    match response {
        Some(r) => Ok(r.text().await?),
        None => {
            let body = curl_get(url).await?;
            // curl got through where we couldn't: remember, and stop paying for
            // the failing attempt on every future refresh.
            curl_only_hosts().lock().unwrap().insert(host);
            Ok(body)
        }
    }
}

pub async fn fetch_json<T: DeserializeOwned>(
    client: &reqwest::Client,
    url: &str,
) -> Result<T, ProviderError> {
    let body = fetch_text(client, url).await?;
    serde_json::from_str(&body).map_err(|e| ProviderError::Parse(e.to_string()))
}

/// True when the request died before a response was received, which is the
/// only case where falling back to another HTTP client can help.
fn is_connection_error(e: &reqwest::Error) -> bool {
    e.is_connect() || e.is_timeout() || e.is_request()
}

async fn curl_get(url: &str) -> Result<String, ProviderError> {
    let output = tokio::process::Command::new("curl")
        .arg("--silent")
        .arg("--show-error")
        .arg("--location")
        .arg("--fail")
        .arg("--max-time")
        .arg(TIMEOUT.as_secs().to_string())
        .arg("--user-agent")
        .arg(USER_AGENT)
        .arg("--")
        .arg(url)
        .output()
        .await
        .map_err(|e| ProviderError::Message(format!("connection refused, and curl fallback failed: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(ProviderError::Message(format!(
            "connection refused by the server's TLS layer; curl fallback also failed: {}",
            stderr.trim()
        )));
    }

    String::from_utf8(output.stdout)
        .map_err(|e| ProviderError::Parse(format!("response was not valid UTF-8: {e}")))
}

pub async fn fetch_site(
    client: &reqwest::Client,
    site: &SiteConfig,
) -> Result<SiteStatus, ProviderError> {
    match site.adapter {
        AdapterKind::Statuspage => statuspage::fetch(client, site).await,
        AdapterKind::Flashduty => flashduty::fetch(client, site).await,
    }
}

/// Fetches every site concurrently, capturing per-site errors as `Unknown`
/// status instead of failing the whole batch.
///
/// Takes the client rather than building one so callers can share connection
/// pooling across refreshes — see [`build_client`].
pub async fn fetch_all(client: &reqwest::Client, sites: &[SiteConfig]) -> Vec<SiteStatus> {
    let results = futures::future::join_all(sites.iter().map(|s| fetch_site(client, s))).await;

    sites
        .iter()
        .zip(results)
        .map(|(site, result)| match result {
            Ok(status) => status,
            Err(err) => SiteStatus::from_error(site, &err.to_string()),
        })
        .collect()
}

/// Probes a status page URL to work out which adapter can read it, so the user
/// never has to know whether a page is StatusPage- or FlashDuty-flavored.
///
/// Both probes run at once: a page that isn't StatusPage-flavored can take the
/// full request timeout to say so, and serializing that behind the FlashDuty
/// probe would double the worst case.
///
/// Returns `None` when neither adapter recognizes the page.
pub async fn detect_adapter(client: &reqwest::Client, url: &str) -> Option<AdapterKind> {
    let probe = |adapter| SiteConfig {
        id: String::new(),
        name: String::new(),
        url: url.trim_end_matches('/').to_string(),
        adapter,
    };

    let (sp, fd) = futures::future::join(
        statuspage::fetch(client, &probe(AdapterKind::Statuspage)),
        flashduty::fetch(client, &probe(AdapterKind::Flashduty)),
    )
    .await;

    match (sp.is_ok(), fd.is_ok()) {
        (true, _) => Some(AdapterKind::Statuspage),
        (false, true) => Some(AdapterKind::Flashduty),
        (false, false) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_of_extracts_the_authority() {
        assert_eq!(host_of("https://status.deepseek.com/api/x.json"), "status.deepseek.com");
        assert_eq!(host_of("https://status.claude.com"), "status.claude.com");
        assert_eq!(host_of("http://example.com:8080/a/b"), "example.com:8080");
    }

    /// The memo is keyed by host, so every path on a site that needs the curl
    /// fallback benefits once any one of them has proven it.
    #[test]
    fn curl_memo_is_shared_across_paths_on_a_host() {
        let summary = host_of("https://example.invalid/api/v2/summary.json");
        let page = host_of("https://example.invalid/");
        assert_eq!(summary, page);
    }
}

impl SiteStatus {
    pub fn from_error(site: &SiteConfig, message: &str) -> Self {
        SiteStatus {
            id: site.id.clone(),
            name: site.name.clone(),
            url: site.url.clone(),
            adapter: format!("{:?}", site.adapter).to_lowercase(),
            overall: crate::model::Status::Unknown,
            components: Vec::new(),
            incidents: Vec::new(),
            fetched_at: Some(chrono::Utc::now().to_rfc3339()),
            error: Some(message.to_string()),
            icon: None,
        }
    }
}
