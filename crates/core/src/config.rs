use serde::{Deserialize, Serialize};

use crate::model::Status;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdapterKind {
    Statuspage,
    Flashduty,
}

/// How the tray icon expresses status.
///
/// The three are genuinely different trades, not three skins, so the choice is
/// the user's: how much of the menu bar's quiet the icon is allowed to spend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IconStyle {
    /// The mark gets louder as the news gets worse: monochrome while healthy,
    /// tinted when degraded, filled when something is down. Weight survives
    /// peripheral vision in a way hue alone does not.
    #[default]
    Escalating,
    /// Monochrome glyph in every state, status carried by the corner lamp
    /// alone. The quietest of the three, and the hardest to read at a glance.
    Lamp,
    /// The whole glyph carries the status colour in every state, healthy
    /// included. One rule to learn, at the cost of colour in the bar all day.
    Tinted,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteConfig {
    pub id: String,
    pub name: String,
    pub url: String,
    pub adapter: AdapterKind,
}

fn default_interval() -> u64 {
    300
}
fn default_true() -> bool {
    true
}
fn default_false() -> bool {
    false
}
fn default_priority() -> Vec<Status> {
    Status::DEFAULT_PRIORITY.to_vec()
}

pub fn default_sites() -> Vec<SiteConfig> {
    vec![
        SiteConfig {
            id: "claude".into(),
            name: "Claude".into(),
            url: "https://status.claude.com".into(),
            adapter: AdapterKind::Statuspage,
        },
        SiteConfig {
            id: "openai".into(),
            name: "OpenAI".into(),
            url: "https://status.openai.com".into(),
            adapter: AdapterKind::Statuspage,
        },
        SiteConfig {
            id: "deepseek".into(),
            name: "DeepSeek".into(),
            url: "https://status.deepseek.com".into(),
            adapter: AdapterKind::Flashduty,
        },
    ]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_interval")]
    pub refresh_interval_seconds: u64,
    #[serde(default = "default_true")]
    pub notifications_enabled: bool,
    #[serde(default = "default_false")]
    pub launch_at_login: bool,
    #[serde(default = "default_priority")]
    pub status_priority: Vec<Status>,
    #[serde(default)]
    pub icon_style: IconStyle,
    #[serde(default)]
    pub sites: Vec<SiteConfig>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            refresh_interval_seconds: default_interval(),
            notifications_enabled: default_true(),
            launch_at_login: default_false(),
            status_priority: default_priority(),
            icon_style: IconStyle::default(),
            sites: default_sites(),
        }
    }
}

impl Config {
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    pub fn from_json_or_default(json: &str) -> Self {
        serde_json::from_str(json).unwrap_or_default()
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }
}
