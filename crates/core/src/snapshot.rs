use std::collections::HashMap;

use serde::Serialize;

use crate::model::{Incident, SiteStatus, Status};

/// A detected change in a single site between two fetches.
#[derive(Debug, Clone, Serialize)]
pub struct StatusChange {
    pub site_id: String,
    pub site_name: String,
    pub old_overall: Status,
    pub new_overall: Status,
    /// Newly appearing incidents (by id) since the previous snapshot.
    pub new_incidents: Vec<Incident>,
}

/// Compares a fresh batch of statuses against the previous snapshot and returns
/// one [`StatusChange`] per site whose overall status changed or that gained new
/// incidents. Used to drive notifications.
pub fn detect_changes(
    before: &HashMap<String, SiteStatus>,
    after: &[SiteStatus],
) -> Vec<StatusChange> {
    after
        .iter()
        .filter_map(|curr| {
            let prev = before.get(&curr.id);
            let status_changed = prev.map(|p| p.overall != curr.overall).unwrap_or(false);

            let prev_incident_ids: std::collections::HashSet<&str> = prev
                .map(|p| p.incidents.iter().map(|i| i.id.as_str()).collect())
                .unwrap_or_default();
            let new_incidents: Vec<Incident> = curr
                .incidents
                .iter()
                .filter(|i| !prev_incident_ids.contains(i.id.as_str()))
                .cloned()
                .collect();

            if status_changed || !new_incidents.is_empty() {
                Some(StatusChange {
                    site_id: curr.id.clone(),
                    site_name: curr.name.clone(),
                    old_overall: prev.map(|p| p.overall).unwrap_or(Status::Unknown),
                    new_overall: curr.overall,
                    new_incidents,
                })
            } else {
                None
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Incident, SiteStatus, Status};

    fn site(id: &str, overall: Status, incident_ids: &[&str]) -> SiteStatus {
        SiteStatus {
            id: id.into(),
            name: id.into(),
            url: "https://status.example.com".into(),
            adapter: "statuspage".into(),
            overall,
            components: Vec::new(),
            incidents: incident_ids
                .iter()
                .map(|i| Incident {
                    id: (*i).into(),
                    title: "t".into(),
                    impact: Status::Unknown,
                    lifecycle: "identified".into(),
                    latest_update: String::new(),
                    updated_at: None,
                    url: None,
                })
                .collect(),
            fetched_at: None,
            error: None,
        }
    }

    #[test]
    fn detects_status_change() {
        let before = HashMap::from([("a".to_string(), site("a", Status::Operational, &[]))]);
        let after = vec![site("a", Status::FullOutage, &[])];
        let changes = detect_changes(&before, &after);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].new_overall, Status::FullOutage);
    }

    #[test]
    fn detects_new_incident() {
        let before = HashMap::from([("a".to_string(), site("a", Status::Operational, &[]))]);
        let after = vec![site("a", Status::Operational, &["inc-1"])];
        let changes = detect_changes(&before, &after);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].new_incidents.len(), 1);
    }

    #[test]
    fn no_change_is_empty() {
        let before = HashMap::from([("a".to_string(), site("a", Status::Operational, &["inc-1"]))]);
        let after = vec![site("a", Status::Operational, &["inc-1"])];
        assert!(detect_changes(&before, &after).is_empty());
    }

    #[test]
    fn new_site_does_not_fire() {
        let before = HashMap::new();
        let after = vec![site("a", Status::Operational, &[])];
        assert!(detect_changes(&before, &after).is_empty());
    }
}
