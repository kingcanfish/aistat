//! FlashDuty / Flashcat status page widget adapter.
//!
//! Schema: <https://docs.flashduty.com/zh/on-call/statuspage/widgets>
//! `GET {page}/api/widget/v1/summary.json`, public and CORS-enabled.

use serde::Deserialize;

use super::{fetch_json, ProviderError};
use crate::config::SiteConfig;
use crate::model::{Component, Incident, SiteStatus, Status};
use crate::normalize::flashduty_status;

pub const WIDGET_PATH: &str = "/api/widget/v1/summary.json";

#[derive(Deserialize, Default)]
pub struct WidgetSummary {
    #[serde(default)]
    pub schema_version: String,
    #[serde(default)]
    pub generated_at: Option<String>,
    #[serde(default)]
    pub max_stale_seconds: Option<i64>,
    #[serde(default)]
    pub page: Option<Page>,
    #[serde(default)]
    pub overall: OverallBlock,
    #[serde(default)]
    pub ongoing_incidents: Vec<Event>,
    #[serde(default)]
    pub in_progress_maintenances: Vec<Event>,
    #[serde(default)]
    pub scheduled_maintenances: Vec<Event>,
    /// Set on the documented error envelopes (`status_page_not_found`,
    /// `widget_summary_unavailable`), which are returned with a JSON body.
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct Page {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct OverallBlock {
    #[serde(default)]
    pub status: Option<String>,
}

/// Both incidents and maintenances use this shape; only a few fields differ.
#[derive(Deserialize, Default)]
pub struct Event {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// investigating / identified / monitoring, or scheduled / ongoing.
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub impact: Option<String>,
    #[serde(default)]
    pub updated_at: Option<String>,
    #[serde(default)]
    pub starts_at: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub last_update: Option<LastUpdate>,
    #[serde(default)]
    pub affected_components: Vec<AffectedComponent>,
}

#[derive(Deserialize, Default)]
pub struct LastUpdate {
    #[serde(default)]
    pub at: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct AffectedComponent {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub group_name: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
}

impl Event {
    fn into_incident(self, fallback_impact: Status) -> Incident {
        // An open event reporting "operational" impact hasn't been classified
        // yet; showing it green would claim it's already resolved.
        let impact = self
            .impact
            .as_deref()
            .map(flashduty_status)
            .filter(|s| !matches!(s, Status::Unknown | Status::Operational))
            .unwrap_or(fallback_impact);

        let (update_at, message) = match self.last_update {
            Some(u) => (u.at, u.message.unwrap_or_default()),
            None => (None, String::new()),
        };

        Incident {
            id: self.id,
            title: if self.title.is_empty() {
                "Untitled incident".into()
            } else {
                self.title
            },
            impact,
            lifecycle: self.phase,
            latest_update: message,
            updated_at: self.updated_at.or(update_at).or(self.starts_at),
            url: self.url,
        }
    }
}

/// Components aren't published as a standalone list; the widget only names the
/// ones an active event touches, so that's what we surface.
fn components_from(events: &[Event]) -> Vec<Component> {
    let mut out: Vec<Component> = Vec::new();
    for event in events {
        for c in &event.affected_components {
            if c.name.is_empty() {
                continue;
            }
            let name = match &c.group_name {
                Some(g) if !g.is_empty() => format!("{g} / {}", c.name),
                _ => c.name.clone(),
            };
            if out.iter().any(|existing| existing.name == name) {
                continue;
            }
            out.push(Component {
                name,
                status: c.status.as_deref().map(flashduty_status).unwrap_or(Status::Unknown),
            });
        }
    }
    out
}

pub fn summary_to_status(site: &SiteConfig, w: WidgetSummary) -> Result<SiteStatus, ProviderError> {
    if let Some(err) = w.error {
        return Err(ProviderError::Parse(match err.as_str() {
            "status_page_not_found" => "status page not found, private, or widget disabled".into(),
            "widget_summary_unavailable" => "widget data temporarily unavailable".into(),
            other => other.to_string(),
        }));
    }

    let mut overall = w
        .overall
        .status
        .as_deref()
        .map(flashduty_status)
        .unwrap_or(Status::Unknown);

    if !w.in_progress_maintenances.is_empty() && overall == Status::Operational {
        overall = Status::Maintenance;
    }

    let components = {
        let mut all = components_from(&w.ongoing_incidents);
        all.extend(components_from(&w.in_progress_maintenances));
        all
    };

    let incident_fallback = if overall == Status::Operational {
        Status::Unknown
    } else {
        overall
    };
    let mut incidents: Vec<Incident> = w
        .ongoing_incidents
        .into_iter()
        .map(|e| e.into_incident(incident_fallback))
        .collect();
    incidents.extend(
        w.in_progress_maintenances
            .into_iter()
            .map(|e| e.into_incident(Status::Maintenance)),
    );

    Ok(SiteStatus {
        id: site.id.clone(),
        name: site.name.clone(),
        url: site.url.clone(),
        adapter: "flashduty".into(),
        overall,
        components,
        incidents,
        fetched_at: Some(chrono::Utc::now().to_rfc3339()),
        error: None,
        icon: None,
    })
}

/// Fetches a FlashDuty/Flashcat status page via its public widget JSON API.
pub async fn fetch(
    client: &reqwest::Client,
    site: &SiteConfig,
) -> Result<SiteStatus, ProviderError> {
    let url = format!("{}{WIDGET_PATH}", site.url.trim_end_matches('/'));
    let w: WidgetSummary = fetch_json(client, &url).await?;
    summary_to_status(site, w)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn site() -> SiteConfig {
        SiteConfig {
            id: "deepseek".into(),
            name: "DeepSeek".into(),
            url: "https://status.deepseek.com".into(),
            adapter: crate::config::AdapterKind::Flashduty,
        }
    }

    #[test]
    fn maps_flashduty_statuses() {
        assert_eq!(flashduty_status("operational"), Status::Operational);
        assert_eq!(flashduty_status("degraded"), Status::Degraded);
        assert_eq!(flashduty_status("partial_outage"), Status::PartialOutage);
        assert_eq!(flashduty_status("full_outage"), Status::FullOutage);
        assert_eq!(flashduty_status("under_maintenance"), Status::Maintenance);
        assert_eq!(flashduty_status("nonsense"), Status::Unknown);
    }

    #[test]
    fn parses_live_shape_with_no_events() {
        let json = r#"{
            "schema_version": "1.0",
            "generated_at": "2026-07-24T02:49:05Z",
            "poll_after_seconds": 30,
            "max_stale_seconds": 120,
            "page": {"name": "DeepSeek", "url": "https://status.deepseek.com"},
            "overall": {"status": "operational"},
            "ongoing_incidents": [],
            "in_progress_maintenances": [],
            "scheduled_maintenances": []
        }"#;
        let w: WidgetSummary = serde_json::from_str(json).unwrap();
        let s = summary_to_status(&site(), w).unwrap();
        assert_eq!(s.overall, Status::Operational);
        assert!(s.incidents.is_empty());
        assert!(s.components.is_empty());
    }

    #[test]
    fn reads_documented_incident_fields() {
        let json = r#"{
            "overall": {"status": "partial_outage"},
            "ongoing_incidents": [{
                "id": "inc-1",
                "title": "API degraded",
                "phase": "identified",
                "impact": "degraded",
                "started_at": "2026-07-24T02:00:00Z",
                "updated_at": "2026-07-24T02:10:00Z",
                "url": "https://status.deepseek.com/incidents/inc-1",
                "last_update": {"at": "2026-07-24T02:10:00Z", "message": "Mitigation applied"},
                "affected_components": [
                    {"id": "c1", "name": "Chat", "group_name": "Web", "status": "degraded"},
                    {"id": "c2", "name": "API", "status": "partial_outage"}
                ]
            }],
            "in_progress_maintenances": [],
            "scheduled_maintenances": []
        }"#;
        let w: WidgetSummary = serde_json::from_str(json).unwrap();
        let s = summary_to_status(&site(), w).unwrap();

        assert_eq!(s.overall, Status::PartialOutage);
        let inc = &s.incidents[0];
        assert_eq!(inc.id, "inc-1");
        assert_eq!(inc.lifecycle, "identified");
        assert_eq!(inc.impact, Status::Degraded);
        assert_eq!(inc.latest_update, "Mitigation applied");
        assert_eq!(inc.updated_at.as_deref(), Some("2026-07-24T02:10:00Z"));

        assert_eq!(s.components.len(), 2);
        assert_eq!(s.components[0].name, "Web / Chat");
        assert_eq!(s.components[0].status, Status::Degraded);
        assert_eq!(s.components[1].name, "API");
    }

    #[test]
    fn maintenance_shows_up_as_an_incident_and_raises_overall() {
        let json = r#"{
            "overall": {"status": "operational"},
            "ongoing_incidents": [],
            "in_progress_maintenances": [{
                "id": "m1",
                "title": "Database upgrade",
                "phase": "ongoing",
                "starts_at": "2026-07-24T01:00:00Z",
                "updated_at": "2026-07-24T01:05:00Z",
                "last_update": {"at": "2026-07-24T01:05:00Z", "message": "Started"},
                "affected_components": [{"id": "c1", "name": "API", "status": "maintenance"}]
            }]
        }"#;
        let w: WidgetSummary = serde_json::from_str(json).unwrap();
        let s = summary_to_status(&site(), w).unwrap();

        assert_eq!(s.overall, Status::Maintenance);
        assert_eq!(s.incidents.len(), 1);
        assert_eq!(s.incidents[0].impact, Status::Maintenance);
        assert_eq!(s.incidents[0].title, "Database upgrade");
        assert_eq!(s.components[0].name, "API");
    }

    #[test]
    fn an_outage_is_not_downgraded_to_maintenance() {
        let json = r#"{
            "overall": {"status": "full_outage"},
            "in_progress_maintenances": [{"id":"m1","title":"Upgrade","phase":"ongoing"}]
        }"#;
        let w: WidgetSummary = serde_json::from_str(json).unwrap();
        assert_eq!(summary_to_status(&site(), w).unwrap().overall, Status::FullOutage);
    }

    #[test]
    fn error_envelope_becomes_a_provider_error() {
        let w: WidgetSummary =
            serde_json::from_str(r#"{"error": "status_page_not_found"}"#).unwrap();
        let err = summary_to_status(&site(), w).unwrap_err();
        assert!(err.to_string().contains("widget disabled"), "{err}");
    }
}
