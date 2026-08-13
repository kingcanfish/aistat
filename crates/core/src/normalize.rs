use crate::model::Status;

/// Maps a StatusPage/incident.io overall `indicator` value to the unified enum.
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

/// Maps a StatusPage/incident.io component status to the unified enum.
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

/// Maps a FlashDuty widget `overall.status` / incident status to the unified enum.
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
