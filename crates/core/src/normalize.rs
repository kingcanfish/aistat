//! Maps provider-specific status vocabularies onto [`Status`].
//!
//! StatusPage reference: <https://metastatuspage.com/api> (every Atlassian
//! Statuspage serves the same docs at `/api`). The public v2 API defines four
//! closed value sets, quoted below. Anything outside them maps to
//! [`Status::Unknown`] rather than being guessed at.
//!
//! FlashDuty reference: <https://docs.flashduty.com/zh/on-call/statuspage/widgets>

use crate::model::Status;

/// Maps the page-level `status.indicator` to the unified enum.
///
/// Documented values — `none` (All Systems Operational), `minor` (Minor issues
/// present), `major` (Significant service disruption), `critical` (Severe
/// outage affecting core functionality).
///
/// Statuspage describes this field as "calculated from a blend of component
/// statuses (or an optional override)". The override is the reason a page can
/// advertise `minor` while its component table shows partial outages, and why
/// [`crate::providers::statuspage`] takes the worst of both.
///
/// `maintenance` is not in the public spec; incident.io-hosted pages emit it,
/// so it is accepted here.
pub fn statuspage_indicator_to_status(v: &str) -> Status {
    match v {
        "none" => Status::Operational,
        "minor" => Status::Degraded,
        "major" => Status::PartialOutage,
        "critical" => Status::FullOutage,
        "maintenance" => Status::Maintenance,
        _ => Status::Unknown,
    }
}

/// Maps an incident's `impact` to the unified enum.
///
/// Documented values, with the colors Statuspage's own UI uses — `none`
/// (black, "No user impact"), `minor` (yellow), `major` (orange), `critical`
/// (red).
///
/// This deliberately differs from [`statuspage_indicator_to_status`] on
/// `none`. At page level `none` means "all systems operational"; on an
/// incident it means the impact has not been classified — and Statuspage
/// itself renders it black, never the operational green. `summary.json`
/// returns only unresolved incidents, so such an incident is still open.
pub fn statuspage_incident_impact(v: &str) -> Status {
    match v {
        "none" | "" => Status::Unknown,
        "minor" => Status::Degraded,
        "major" => Status::PartialOutage,
        "critical" => Status::FullOutage,
        _ => Status::Unknown,
    }
}

/// Maps a component's `status` to the unified enum.
///
/// Documented values — `operational` (Full functionality),
/// `degraded_performance` (Reduced performance), `partial_outage` (Some
/// features unavailable), `major_outage` (Component entirely down).
///
/// `under_maintenance` is absent from the public v2 docs but is a real
/// component state in Statuspage's management API, so it is accepted here.
pub fn statuspage_component_status(v: &str) -> Status {
    match v {
        "operational" => Status::Operational,
        "degraded_performance" => Status::Degraded,
        "partial_outage" => Status::PartialOutage,
        "major_outage" => Status::FullOutage,
        "under_maintenance" => Status::Maintenance,
        _ => Status::Unknown,
    }
}

/// Scheduled-maintenance `status` values that mean "happening right now".
///
/// Documented lifecycle — `scheduled`, `in_progress`, `verifying`,
/// `completed`.
pub fn statuspage_maintenance_is_active(v: &str) -> bool {
    matches!(v, "in_progress" | "verifying")
}

/// Maps a FlashDuty widget `overall.status` / event `impact` to the unified
/// enum.
///
/// Documented values — `operational`, `degraded`, `partial_outage`,
/// `full_outage`, `maintenance`. The extra spellings are tolerated because the
/// widget is also used by self-hosted Flashcat pages.
pub fn flashduty_status(v: &str) -> Status {
    match v {
        "operational" => Status::Operational,
        "degraded" | "degraded_performance" => Status::Degraded,
        "partial_outage" => Status::PartialOutage,
        "major_outage" | "full_outage" => Status::FullOutage,
        "maintenance" | "under_maintenance" => Status::Maintenance,
        _ => Status::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Locks in the four documented value sets, so a typo in one of the arms
    /// can't silently downgrade a real outage to Unknown.
    #[test]
    fn covers_every_documented_statuspage_value() {
        for (v, want) in [
            ("none", Status::Operational),
            ("minor", Status::Degraded),
            ("major", Status::PartialOutage),
            ("critical", Status::FullOutage),
        ] {
            assert_eq!(statuspage_indicator_to_status(v), want, "indicator {v}");
        }

        for (v, want) in [
            ("none", Status::Unknown),
            ("minor", Status::Degraded),
            ("major", Status::PartialOutage),
            ("critical", Status::FullOutage),
        ] {
            assert_eq!(statuspage_incident_impact(v), want, "impact {v}");
        }

        for (v, want) in [
            ("operational", Status::Operational),
            ("degraded_performance", Status::Degraded),
            ("partial_outage", Status::PartialOutage),
            ("major_outage", Status::FullOutage),
        ] {
            assert_eq!(statuspage_component_status(v), want, "component {v}");
        }

        for (v, active) in [
            ("scheduled", false),
            ("in_progress", true),
            ("verifying", true),
            ("completed", false),
        ] {
            assert_eq!(statuspage_maintenance_is_active(v), active, "maint {v}");
        }
    }

    #[test]
    fn unrecognized_values_are_unknown_not_operational() {
        for f in [
            statuspage_indicator_to_status,
            statuspage_incident_impact,
            statuspage_component_status,
            flashduty_status,
        ] {
            assert_eq!(f("something_new"), Status::Unknown);
        }
    }
}
