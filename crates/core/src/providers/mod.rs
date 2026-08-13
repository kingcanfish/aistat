pub mod flashduty;
pub mod statuspage;

use std::time::Duration;

use crate::config::{AdapterKind, SiteConfig};
use crate::model::SiteStatus;

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("parse error: {0}")]
    Parse(String),
    #[error("stale data: {0}")]
    Stale(String),
}

fn build_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent(concat!("aiisdown/", env!("CARGO_PKG_VERSION")))
        .build()
        .unwrap_or_default()
}

pub async fn fetch_site(client: &reqwest::Client, site: &SiteConfig) -> Result<SiteStatus, ProviderError> {
    match site.adapter {
        AdapterKind::Statuspage => statuspage::fetch(client, site).await,
        AdapterKind::Flashduty => flashduty::fetch(client, site).await,
    }
}

/// Fetches every site concurrently, capturing per-site errors as `Unknown`
/// status instead of failing the whole batch.
pub async fn fetch_all(sites: &[SiteConfig]) -> Vec<SiteStatus> {
    let client = build_client();
    let results = futures::future::join_all(sites.iter().map(|s| fetch_site(&client, s))).await;

    sites
        .iter()
        .zip(results)
        .map(|(site, result)| match result {
            Ok(status) => status,
            Err(err) => SiteStatus::from_error(site, &err.to_string()),
        })
        .collect()
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
        }
    }
}
