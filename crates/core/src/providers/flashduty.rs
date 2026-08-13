use serde::Deserialize;
use serde_json::Value;

use super::ProviderError;
use crate::config::SiteConfig;
use crate::model::{Incident, SiteStatus, Status};
use crate::normalize::flashduty_status;

#[derive(Deserialize)]
struct WidgetSummary {
    #[serde(default)]
    overall: OverallBlock,
    #[serde(default)]
    ongoing_incidents: Vec<Value>,
    #[serde(default)]
    in_progress_maintenances: Vec<Value>,
}

#[derive(Deserialize, Default)]
struct OverallBlock {
    #[serde(default)]
    status: Option<String>,
}

/// Best-effort extraction of a string field, trying several candidate keys.
fn pick_str(v: &Value, keys: &[&str]) -> Option<String> {
    for k in keys {
        if let Some(s) = v.get(k).and_then(|x| x.as_str()) {
            let s = s.trim();
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// The FlashDuty widget schema for incident objects is not formally documented;
/// parse defensively against a handful of plausible field names.
fn incident_from_value(v: &Value) -> Incident {
    let id = pick_str(v, &["id", "incident_id", "change_id"]).unwrap_or_default();
    let title = pick_str(v, &["title", "name"]).unwrap_or_else(|| "Untitled incident".into());
    let impact = pick_str(v, &["impact", "severity", "status"])
        .map(|s| flashduty_status(&s))
        .unwrap_or(Status::Unknown);
    let lifecycle = pick_str(v, &["status", "state"]).unwrap_or_default();
    let updated_at = pick_str(v, &["updated_at", "updated", "last_updated_at", "resolved_at"]);
    let url = pick_str(v, &["url", "shortlink", "html_url"]);

    let latest_update = pick_str(v, &["description", "message", "content"])
        .or_else(|| {
            v.get("updates")
                .and_then(|u| u.as_array())
                .and_then(|arr| arr.last())
                .and_then(|last| pick_str(last, &["content", "body", "message", "description"]))
        })
        .or_else(|| {
            v.get("latest_update").and_then(|u| {
                pick_str(u, &["content", "body", "message", "description"])
                    .or_else(|| u.as_str().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()))
            })
        })
        .unwrap_or_default();

    Incident {
        id,
        title,
        impact,
        lifecycle,
        latest_update,
        updated_at,
        url,
    }
}

/// Fetches a FlashDuty/Flashcat status page via its public widget JSON API.
pub async fn fetch(client: &reqwest::Client, site: &SiteConfig) -> Result<SiteStatus, ProviderError> {
    let url = format!("{}/api/widget/v1/summary.json", site.url.trim_end_matches('/'));
    let w: WidgetSummary = client
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .map_err(|e| ProviderError::Parse(e.to_string()))?;

    let mut overall = w
        .overall
        .status
        .as_deref()
        .map(flashduty_status)
        .unwrap_or(Status::Unknown);

    if !w.in_progress_maintenances.is_empty() {
        overall = Status::Maintenance;
    }

    let incidents = w.ongoing_incidents.iter().map(incident_from_value).collect();

    Ok(SiteStatus {
        id: site.id.clone(),
        name: site.name.clone(),
        url: site.url.clone(),
        adapter: "flashduty".into(),
        overall,
        components: Vec::new(),
        incidents,
        fetched_at: Some(chrono::Utc::now().to_rfc3339()),
        error: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn parses_widget_summary() {
        let json = r#"{
            "schema_version": "1.0",
            "generated_at": "2026-07-24T02:49:05Z",
            "max_stale_seconds": 120,
            "page": {"name": "DeepSeek", "url": "https://status.deepseek.com"},
            "overall": {"status": "operational"},
            "ongoing_incidents": [],
            "in_progress_maintenances": [],
            "scheduled_maintenances": []
        }"#;
        let w: WidgetSummary = serde_json::from_str(json).unwrap();
        assert_eq!(w.overall.status.as_deref(), Some("operational"));
        assert!(w.ongoing_incidents.is_empty());
    }

    #[test]
    fn extracts_incident_fields_defensively() {
        let v: Value = serde_json::from_str(
            r#"{
                "id": "inc-1",
                "title": "API degraded",
                "impact": "degraded",
                "status": "identified",
                "updates": [
                    {"content": "Investigating", "created_at": "2026-07-24T02:00:00Z"},
                    {"content": "Mitigation applied", "created_at": "2026-07-24T02:10:00Z"}
                ]
            }"#,
        )
        .unwrap();
        let inc = incident_from_value(&v);
        assert_eq!(inc.id, "inc-1");
        assert_eq!(inc.title, "API degraded");
        assert_eq!(inc.impact, Status::Degraded);
        assert_eq!(inc.latest_update, "Mitigation applied");
    }

    #[test]
    fn maintenance_overrides_overall() {
        let mut overall = flashduty_status("operational");
        let in_progress: Vec<Value> = vec![serde_json::from_str(r#"{"id":"m1"}"#).unwrap()];
        if !in_progress.is_empty() {
            overall = Status::Maintenance;
        }
        assert_eq!(overall, Status::Maintenance);
    }
}
