use serde::{Deserialize, Serialize};

/// Unified status enum shared by all providers.
///
/// The discriminant order is used as a fallback severity ranking (higher is
/// more severe) but the canonical priority lives in [`Config::status_priority`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Operational,
    Degraded,
    PartialOutage,
    FullOutage,
    Maintenance,
    Unknown,
}

impl Status {
    /// Default aggregation priority, most severe first.
    pub const DEFAULT_PRIORITY: [Status; 6] = [
        Status::FullOutage,
        Status::PartialOutage,
        Status::Maintenance,
        Status::Degraded,
        Status::Operational,
        Status::Unknown,
    ];

    /// Returns the severity index of this status within `priority` (lower is
    /// more severe). Unknown statuses not present in the list rank least severe.
    pub fn severity(self, priority: &[Status]) -> usize {
        priority
            .iter()
            .position(|s| *s == self)
            .unwrap_or(usize::MAX)
    }

    /// Human readable label for UI display.
    pub fn label(self) -> &'static str {
        match self {
            Status::Operational => "Operational",
            Status::Degraded => "Degraded",
            Status::PartialOutage => "Partial Outage",
            Status::FullOutage => "Full Outage",
            Status::Maintenance => "Maintenance",
            Status::Unknown => "Unknown",
        }
    }

    /// CSS/emoji color token for the frontend.
    pub fn color(self) -> &'static str {
        match self {
            Status::Operational => "green",
            Status::Degraded => "yellow",
            Status::PartialOutage => "orange",
            Status::FullOutage => "red",
            Status::Maintenance => "blue",
            Status::Unknown => "gray",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Component {
    pub name: String,
    pub status: Status,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Incident {
    pub id: String,
    pub title: String,
    pub impact: Status,
    /// Incident lifecycle (investigating / identified / monitoring / resolved).
    pub lifecycle: String,
    /// Latest update/description text.
    pub latest_update: String,
    pub updated_at: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteStatus {
    pub id: String,
    pub name: String,
    pub url: String,
    pub adapter: String,
    pub overall: Status,
    pub components: Vec<Component>,
    pub incidents: Vec<Incident>,
    pub fetched_at: Option<String>,
    pub error: Option<String>,
}
