use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Instant;

use aistat_core::config::Config;
use aistat_core::model::SiteStatus;

/// Screen rect of the tray icon, in physical pixels, as reported by the last
/// tray icon event. Used to anchor the panel underneath the icon.
#[derive(Debug, Clone, Copy)]
pub struct TrayAnchor {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

pub struct AppState {
    /// One client for the whole process: reqwest pools connections and reuses
    /// TLS sessions per client, so rebuilding it per refresh would double the
    /// time each refresh takes.
    pub http: aistat_core::HttpClient,
    pub config_path: PathBuf,
    pub config: Mutex<Config>,
    pub statuses: Mutex<Vec<SiteStatus>>,
    pub previous: Mutex<HashMap<String, SiteStatus>>,
    /// Site URL -> resolved icon URL. `Some(None)` records a page we already
    /// checked and that has no usable icon, so we don't refetch its HTML on
    /// every poll.
    pub icons: Mutex<HashMap<String, Option<String>>>,
    pub tray_anchor: Mutex<Option<TrayAnchor>>,
    /// When the panel was last hidden. Clicking the tray icon while the panel
    /// is open first blurs (and hides) it, so a click arriving right after a
    /// hide must be swallowed instead of re-opening the panel.
    pub hidden_at: Mutex<Option<Instant>>,
    /// Set while the settings form is open, so a stray click elsewhere doesn't
    /// dismiss the panel and throw away what the user was typing.
    pub pinned: Mutex<bool>,
}
