use serde::Deserialize;

use super::ProviderError;
use crate::config::SiteConfig;
use crate::model::{Component, Incident, SiteStatus, Status};
use crate::normalize::{statuspage_component_status, statuspage_indicator_to_status};

#[derive(Deserialize)]
struct Summary {
    status: StatusBlock,
    #[serde(default)]
    components: Vec<ComponentRaw>,
    #[serde(default)]
    incidents: Vec<IncidentRaw>,
    #[serde(default)]
    scheduled_maintenances: Vec<MaintenanceRaw>,
}

#[derive(Deserialize)]
struct StatusBlock {
    #[serde(default)]
    indicator: String,
}

#[derive(Deserialize)]
struct ComponentRaw {
    name: String,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    group: bool,
}

#[derive(Deserialize)]
struct IncidentRaw {
    id: String,
    name: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    impact: String,
    #[serde(default)]
    updated_at: Option<String>,
    #[serde(default)]
    shortlink: Option<String>,
    #[serde(default)]
    incident_updates: Vec<UpdateRaw>,
}

#[derive(Deserialize)]
struct UpdateRaw {
    #[serde(default)]
    body: String,
}

#[derive(Deserialize)]
struct MaintenanceRaw {
    #[serde(default)]
    status: String,
}

/// Fetches a StatusPage-compatible status page (Atlassian StatusPage and
/// incident.io both expose this JSON schema) using a single `summary.json` call.
pub async fn fetch(client: &reqwest::Client, site: &SiteConfig) -> Result<SiteStatus, ProviderError> {
    let url = format!("{}/api/v2/summary.json", site.url.trim_end_matches('/'));
    let summary: Summary = client
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .map_err(|e| ProviderError::Parse(e.to_string()))?;

    let mut overall = statuspage_indicator_to_status(&summary.status.indicator);

    let maintenance_active = summary
        .scheduled_maintenances
        .iter()
        .any(|m| matches!(m.status.as_str(), "in_progress" | "verifying"));
    if maintenance_active {
        overall = Status::Maintenance;
    }

    let components = summary
        .components
        .iter()
        .filter(|c| !c.group)
        .filter_map(|c| {
            c.status.as_ref().map(|s| Component {
                name: c.name.clone(),
                status: statuspage_component_status(s),
            })
        })
        .collect();

    let incidents = summary
        .incidents
        .iter()
        .map(|i| {
            let latest_update = i
                .incident_updates
                .last()
                .map(|u| u.body.clone())
                .unwrap_or_default();
            Incident {
                id: i.id.clone(),
                title: i.name.clone(),
                impact: statuspage_indicator_to_status(&i.impact),
                lifecycle: i.status.clone(),
                latest_update,
                updated_at: i.updated_at.clone(),
                url: i.shortlink.clone(),
            }
        })
        .collect();

    Ok(SiteStatus {
        id: site.id.clone(),
        name: site.name.clone(),
        url: site.url.clone(),
        adapter: "statuspage".into(),
        overall,
        components,
        incidents,
        fetched_at: Some(chrono::Utc::now().to_rfc3339()),
        error: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AdapterKind;

    #[test]
    fn parses_summary_and_maps_indicator() {
        let json = r#"{
            "page": {"id": "x", "name": "Claude", "url": "https://status.claude.com"},
            "status": {"indicator": "none", "description": "All Systems Operational"},
            "components": [
                {"id": "1", "name": "claude.ai", "status": "operational"},
                {"id": "2", "name": "Claude API", "status": "degraded_performance"}
            ],
            "incidents": [],
            "scheduled_maintenances": []
        }"#;
        let summary: Summary = serde_json::from_str(json).unwrap();
        let overall = statuspage_indicator_to_status(&summary.status.indicator);
        assert_eq!(overall, Status::Operational);
        assert_eq!(summary.components.len(), 2);
    }

    #[test]
    fn maps_all_component_statuses() {
        assert_eq!(statuspage_component_status("operational"), Status::Operational);
        assert_eq!(statuspage_component_status("degraded_performance"), Status::Degraded);
        assert_eq!(statuspage_component_status("partial_outage"), Status::PartialOutage);
        assert_eq!(statuspage_component_status("major_outage"), Status::FullOutage);
        assert_eq!(statuspage_component_status("under_maintenance"), Status::Maintenance);
        assert_eq!(statuspage_component_status("bogus"), Status::Unknown);
    }

    #[test]
    fn site_config_kind_roundtrip() {
        let site = SiteConfig {
            id: "x".into(),
            name: "X".into(),
            url: "https://status.example.com".into(),
            adapter: AdapterKind::Statuspage,
        };
        assert_eq!(format!("{:?}", site.adapter).to_lowercase(), "statuspage");
    }
}
