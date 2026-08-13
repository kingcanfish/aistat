use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use aiisdown_core::config::Config;
use aiisdown_core::model::SiteStatus;

pub struct AppState {
    pub config_path: PathBuf,
    pub config: Mutex<Config>,
    pub statuses: Mutex<Vec<SiteStatus>>,
    pub previous: Mutex<HashMap<String, SiteStatus>>,
}
