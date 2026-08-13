use serde::Deserialize;

use super::{fetch_json, ProviderError};
use crate::config::SiteConfig;
use crate::model::{Component, Incident, SiteStatus, Status};
use crate::normalize::{
    statuspage_component_status, statuspage_incident_impact, statuspage_indicator_to_status,
    statuspage_maintenance_is_active,
};

/// Atlassian Statuspage public API v2. Schema and field values are documented
/// at `<page>/api`, e.g. <https://metastatuspage.com/api>.
///
/// `summary.json` returns the page indicator, every component, all *unresolved*
/// incidents, and upcoming plus in-progress maintenances in one request.
pub const SUMMARY_PATH: &str = "/api/v2/summary.json";

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
pub async fn fetch(
    client: &reqwest::Client,
    site: &SiteConfig,
) -> Result<SiteStatus, ProviderError> {
    let url = format!("{}{SUMMARY_PATH}", site.url.trim_end_matches('/'));
    Ok(to_status(site, fetch_json(client, &url).await?))
}

fn to_status(site: &SiteConfig, summary: Summary) -> SiteStatus {
    let components: Vec<Component> = summary
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

    // The page-level indicator is maintained by hand and routinely lags the
    // component table — Anthropic's page reads "minor" while four components
    // report a partial outage. Take the worst of every signal so the tray
    // never under-reports.
    let maintenance_active = summary
        .scheduled_maintenances
        .iter()
        .any(|m| statuspage_maintenance_is_active(&m.status));

    let overall = crate::aggregate(
        std::iter::once(statuspage_indicator_to_status(&summary.status.indicator))
            .chain(components.iter().map(|c| c.status))
            .chain(maintenance_active.then_some(Status::Maintenance)),
        &Status::DEFAULT_PRIORITY,
    );

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
                impact: statuspage_incident_impact(&i.impact),
                lifecycle: i.status.clone(),
                latest_update,
                updated_at: i.updated_at.clone(),
                url: i.shortlink.clone(),
            }
        })
        .collect();

    SiteStatus {
        id: site.id.clone(),
        name: site.name.clone(),
        url: site.url.clone(),
        adapter: "statuspage".into(),
        overall,
        components,
        incidents,
        fetched_at: Some(chrono::Utc::now().to_rfc3339()),
        error: None,
        icon: None,
    }
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

    fn site() -> SiteConfig {
        SiteConfig {
            id: "claude".into(),
            name: "Claude".into(),
            url: "https://status.claude.com".into(),
            adapter: AdapterKind::Statuspage,
        }
    }

    /// status.claude.com reported indicator "minor" while four components were
    /// in partial outage. The panel must show the worse of the two.
    #[test]
    fn overall_escalates_to_the_worst_component() {
        let json = r#"{
            "status": {"indicator": "minor"},
            "components": [
                {"id":"1","name":"Console","status":"operational"},
                {"id":"2","name":"claude.ai","status":"partial_outage"},
                {"id":"3","name":"Claude Code","status":"partial_outage"}
            ],
            "incidents": [],
            "scheduled_maintenances": []
        }"#;
        let s = to_status(&site(), serde_json::from_str(json).unwrap());
        assert_eq!(s.overall, Status::PartialOutage);
    }

    #[test]
    fn component_groups_do_not_drive_the_overall_status() {
        let json = r#"{
            "status": {"indicator": "none"},
            "components": [
                {"id":"1","name":"A group","status":"major_outage","group":true},
                {"id":"2","name":"Real","status":"operational"}
            ]
        }"#;
        let s = to_status(&site(), serde_json::from_str(json).unwrap());
        assert_eq!(s.overall, Status::Operational);
        assert_eq!(s.components.len(), 1);
    }

    #[test]
    fn maintenance_does_not_downgrade_a_worse_signal() {
        let json = r#"{
            "status": {"indicator": "critical"},
            "components": [],
            "scheduled_maintenances": [{"status": "in_progress"}]
        }"#;
        let s = to_status(&site(), serde_json::from_str(json).unwrap());
        assert_eq!(s.overall, Status::FullOutage);
    }

    /// An open incident with impact "none" is unclassified, not resolved.
    #[test]
    fn unclassified_open_incidents_are_not_green() {
        let json = r#"{
            "status": {"indicator": "minor"},
            "incidents": [
                {"id":"a","name":"RBAC roles failing","status":"identified","impact":"none"},
                {"id":"b","name":"Elevated errors","status":"identified","impact":"minor"}
            ]
        }"#;
        let s = to_status(&site(), serde_json::from_str(json).unwrap());
        assert_eq!(s.incidents[0].impact, Status::Unknown);
        assert_eq!(s.incidents[1].impact, Status::Degraded);
    }

    #[test]
    fn page_level_none_still_means_operational() {
        assert_eq!(statuspage_indicator_to_status("none"), Status::Operational);
        assert_eq!(statuspage_incident_impact("none"), Status::Unknown);
        assert_eq!(statuspage_incident_impact("critical"), Status::FullOutage);
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
