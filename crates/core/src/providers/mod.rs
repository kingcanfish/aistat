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
    // Rendered through `chain` because this string is what the menu bar row
    // shows: `reqwest::Error`'s own Display stops at "error sending request
    // for url ...", which tells the user nothing they can act on. The reason —
    // a bad certificate, a refused connection — is in the sources beneath it.
    #[error("{}", chain(.0))]
    Http(#[from] reqwest::Error),
    #[error("parse error: {0}")]
    Parse(String),
}

/// Selects the TLS backend, once per process.
///
/// Some status pages sit behind a device that resets any connection whose
/// ClientHello fits in a single TCP segment — `status.deepseek.com` is one.
/// Measured against it: a 1374-byte ClientHello is reset before the server
/// answers, a 1678-byte one completes the handshake. The post-quantum
/// X25519MLKEM768 key share is ~1.2KB on its own, so offering it pushes every
/// ClientHello past that threshold, which is why `curl --curves
/// X25519MLKEM768` reaches the site when a default Rust client can't.
///
/// [`rustls_graviola`] is the backend because it offers X25519MLKEM768 and is
/// pure Rust: `ring` and `aws-lc-rs` both compile C, which would put a C
/// toolchain (and NASM, on Windows) in the path of all five release targets.
/// Its default group order already puts X25519MLKEM768 first and keeps
/// X25519/secp256r1/secp384r1 behind it, so a server without post-quantum
/// support still negotiates normally.
///
/// Installing fails only when something else got there first, which for a
/// binary with one entry point means a second call from this same function.
fn install_tls_backend() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        if rustls_graviola::default_provider().install_default().is_err() {
            log::warn!("a TLS backend was already installed; leaving it alone");
        }
    });
}

/// Builds the shared HTTP client.
///
/// Build this **once** and reuse it: reqwest pools connections and reuses TLS
/// sessions per client, which halves a warm refresh (measured ~600ms → ~300ms
/// across three sites). A client per refresh throws that away.
pub fn build_client() -> reqwest::Client {
    install_tls_backend();
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .user_agent(USER_AGENT)
        .pool_idle_timeout(Duration::from_secs(300))
        .build()
        .unwrap_or_default()
}

/// GETs `url` and returns the body.
pub async fn fetch_text(client: &reqwest::Client, url: &str) -> Result<String, ProviderError> {
    let response = client.get(url).send().await.inspect_err(|e| {
        log::warn!("{url}: request failed: {}", chain(e));
    })?;
    Ok(response.error_for_status()?.text().await?)
}

pub async fn fetch_json<T: DeserializeOwned>(
    client: &reqwest::Client,
    url: &str,
) -> Result<T, ProviderError> {
    let body = fetch_text(client, url).await?;
    serde_json::from_str(&body).map_err(|e| {
        // The body is the only way to tell "this isn't a status API" from "the
        // schema moved", and it's the one thing the error itself never carries.
        log::warn!("{url}: response was not the expected JSON: {e}; body starts: {:.200}", body);
        ProviderError::Parse(e.to_string())
    })
}

/// Renders an error together with its source chain.
///
/// `reqwest::Error`'s own `Display` stops at "error sending request for url
/// ...", which is the one part we already know. The reason — a TLS alert, a
/// refused connection, a certificate that doesn't match — only lives in the
/// sources underneath it, so a log line without them says nothing.
fn chain(e: &(dyn std::error::Error + 'static)) -> String {
    let mut out = e.to_string();
    let mut source = e.source();
    while let Some(cause) = source {
        out.push_str(": ");
        out.push_str(&cause.to_string());
        source = cause.source();
    }
    out
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
            Err(err) => {
                log::error!("{} ({}): {err}", site.name, site.url);
                SiteStatus::from_error(site, &err.to_string())
            }
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
        (false, false) => {
            // The user only sees "unsupported"; the two probe errors are what
            // actually say whether the page is unreachable or just not a
            // status API.
            log::warn!("{url}: no adapter matched");
            log::warn!("  statuspage probe: {}", sp.unwrap_err());
            log::warn!("  flashduty probe: {}", fd.unwrap_err());
            None
        }
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

#[cfg(test)]
mod tests {
    /// The whole reason for choosing this TLS backend: it has to offer
    /// X25519MLKEM768, and it has to offer it *first*, because that is what
    /// grows the ClientHello past the segment boundary. A backend upgrade that
    /// quietly reorders or drops the group would otherwise only show up as
    /// DeepSeek going Unknown in the menu bar.
    #[test]
    fn tls_backend_offers_a_post_quantum_key_share_first() {
        let groups = rustls_graviola::default_provider().kx_groups;
        let names: Vec<String> = groups.iter().map(|g| format!("{:?}", g.name())).collect();
        assert!(
            names.first().is_some_and(|n| n.contains("MLKEM")),
            "expected a post-quantum group first, got {names:?}"
        );
        // Servers without post-quantum support have to be able to fall back.
        assert!(names.len() > 1, "expected classical groups behind it, got {names:?}");
    }
}
