mod state;
mod tray;

use std::collections::HashMap;

use aiisdown_core::{
    config::Config, detect_changes, fetch_all, model::SiteStatus,
};
use state::AppState;
use tauri::{AppHandle, Emitter, Manager, State};
use tray::update_tray;

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let config_dir = app.path().app_config_dir()?;
            std::fs::create_dir_all(&config_dir).ok();
            let config_path = config_dir.join("config.json");

            let config = load_config(&config_path);
            let state = AppState {
                config_path,
                config: std::sync::Mutex::new(config),
                statuses: std::sync::Mutex::new(Vec::new()),
                previous: std::sync::Mutex::new(HashMap::new()),
            };
            app.manage(state);

            tray::setup_tray(app)?;

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                refresh_once(&handle).await;
                spawn_scheduler(handle).await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_statuses,
            refresh_now,
            get_config,
            set_config,
            open_url
        ])
        .run(tauri::generate_context!())
        .expect("error while running aiisdown");
}

fn load_config(path: &std::path::Path) -> Config {
    match std::fs::read_to_string(path) {
        Ok(text) => Config::from_json_or_default(&text),
        Err(_) => Config::default(),
    }
}

fn save_config(state: &AppState) {
    if let Ok(json) = state.config.lock().unwrap().to_json() {
        std::fs::write(&state.config_path, json).ok();
    }
}

/// Fetches all sites, updates shared state, tray icon, emits an event, and
/// sends notifications for any detected change.
async fn refresh_once(app: &AppHandle) {
    let state = app.state::<AppState>();
    let config = state.config.lock().unwrap().clone();

    let statuses = fetch_all(&config.sites).await;

    let changes = {
        let previous = state.previous.lock().unwrap();
        detect_changes(&previous, &statuses)
    };

    {
        let mut previous = state.previous.lock().unwrap();
        *previous = statuses
            .iter()
            .map(|s| (s.id.clone(), s.clone()))
            .collect();
    }
    *state.statuses.lock().unwrap() = statuses.clone();

    update_tray(app, &statuses, &config);
    let _ = app.emit("status-updated", &statuses);

    if config.notifications_enabled {
        for change in changes {
            notify(&change);
        }
    }
}

async fn spawn_scheduler(app: AppHandle) {
    loop {
        let interval = {
            let state = app.state::<AppState>();
            let seconds = state.config.lock().unwrap().refresh_interval_seconds.max(30);
            seconds
        };
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        refresh_once(&app).await;
    }
}

fn notify(change: &aiisdown_core::StatusChange) {
    let summary = format!("{} — {}", change.site_name, change.new_overall.label());
    let body = if let Some(incident) = change.new_incidents.first() {
        format!("{}\n{}", incident.title, incident.latest_update)
    } else {
        format!(
            "Status changed from {} to {}",
            change.old_overall.label(),
            change.new_overall.label()
        )
    };
    let _ = notify_rust::Notification::new().summary(&summary).body(&body).show();
}

#[tauri::command]
fn get_statuses(state: State<'_, AppState>) -> Vec<SiteStatus> {
    state.statuses.lock().unwrap().clone()
}

#[tauri::command]
async fn refresh_now(app: AppHandle) -> Vec<SiteStatus> {
    refresh_once(&app).await;
    app.state::<AppState>().statuses.lock().unwrap().clone()
}

#[tauri::command]
fn get_config(state: State<'_, AppState>) -> Config {
    state.config.lock().unwrap().clone()
}

#[tauri::command]
fn set_config(app: AppHandle, config: Config) -> Config {
    let state = app.state::<AppState>();
    *state.config.lock().unwrap() = config;
    save_config(&state);
    let result = state.config.lock().unwrap().clone();
    result
}

#[tauri::command]
fn open_url(url: String) {
    if !url.is_empty() {
        let _ = open::that(url);
    }
}
