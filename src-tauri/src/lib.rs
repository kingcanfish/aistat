mod state;
mod tray;

use std::collections::HashMap;

use aistat_core::{
    config::Config, config::SiteConfig, detect_changes, fetch_all, model::SiteStatus, HttpClient,
};
use state::AppState;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tray::update_tray;

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            // A menu bar app lives only in the tray: no Dock icon, and showing
            // the panel must not steal the active app's focus ring.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let config_dir = app.path().app_config_dir()?;
            std::fs::create_dir_all(&config_dir).ok();
            let config_path = config_dir.join("config.json");

            let config = load_config(&config_path);
            let state = AppState {
                http: aistat_core::providers::build_client(),
                config_path,
                config: std::sync::Mutex::new(config),
                statuses: std::sync::Mutex::new(Vec::new()),
                previous: std::sync::Mutex::new(HashMap::new()),
                icons: std::sync::Mutex::new(HashMap::new()),
                tray_anchor: std::sync::Mutex::new(None),
                hidden_at: std::sync::Mutex::new(None),
                pinned: std::sync::Mutex::new(false),
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
        .on_window_event(|window, event| {
            // Native menu bar panels dismiss as soon as they lose focus.
            if let WindowEvent::Focused(false) = event {
                let app = window.app_handle();
                let pinned = *app.state::<AppState>().pinned.lock().unwrap();
                if window.label() == "main" && !pinned {
                    let _ = window.hide();
                    tray::note_panel_hidden(app);
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_statuses,
            refresh_now,
            get_config,
            set_config,
            open_url,
            set_panel_pinned,
            detect_adapter,
            resize_panel
        ])
        .run(tauri::generate_context!())
        .expect("error while running aistat");
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

    let client = state.http.clone();

    // Statuses and icons hit different endpoints and don't depend on each
    // other, so they go out together rather than back to back.
    let (mut statuses, ()) = futures::future::join(
        fetch_all(&client, &config.sites),
        resolve_icons(app, &client, &config.sites),
    )
    .await;
    apply_icons(app, &mut statuses);

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

/// Resolves the icon for any site we haven't seen before, filling the cache.
///
/// Icons are scraped from each page's HTML, so this does real network work the
/// first time a site appears and nothing at all afterwards. It depends only on
/// the configured URLs, not on the fetched statuses, which is why the caller
/// can run it alongside the status fetch instead of after it.
async fn resolve_icons(app: &AppHandle, client: &HttpClient, sites: &[SiteConfig]) {
    let state = app.state::<AppState>();

    let unresolved: Vec<String> = {
        let cache = state.icons.lock().unwrap();
        sites
            .iter()
            .map(|s| s.url.clone())
            .filter(|url| !cache.contains_key(url))
            .collect()
    };
    if unresolved.is_empty() {
        return;
    }

    let resolved = futures::future::join_all(unresolved.into_iter().map(|url: String| async move {
        let icon = aistat_core::providers::icon::fetch_icon_url(client, &url).await;
        (url, icon)
    }))
    .await;

    app.state::<AppState>().icons.lock().unwrap().extend(resolved);
}

fn apply_icons(app: &AppHandle, statuses: &mut [SiteStatus]) {
    let state = app.state::<AppState>();
    let cache = state.icons.lock().unwrap();
    for status in statuses {
        status.icon = cache.get(&status.url).cloned().flatten();
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

fn notify(change: &aistat_core::StatusChange) {
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

/// Lets the panel size itself to its content. `height` is in CSS pixels.
#[tauri::command]
fn resize_panel(app: AppHandle, height: f64) {
    tray::resize_panel(&app, height);
}

/// Works out which adapter can read a status page so the user doesn't have to.
/// Returns the adapter name, or an error naming the site as unsupported.
#[tauri::command]
async fn detect_adapter(app: AppHandle, url: String) -> Result<String, String> {
    let url = normalize_url(&url)?;
    let client = app.state::<AppState>().http.clone();
    match aistat_core::detect_adapter(&client, &url).await {
        Some(kind) => Ok(format!("{kind:?}").to_lowercase()),
        None => Err(format!(
            "{url} doesn't expose a supported status API.\n\nSupported: Atlassian StatusPage / incident.io ({}) and FlashDuty ({}).",
            aistat_core::providers::statuspage::SUMMARY_PATH,
            aistat_core::providers::flashduty::WIDGET_PATH,
        )),
    }
}

/// Keeps the panel open while the settings form has unsaved input.
#[tauri::command]
fn set_panel_pinned(state: State<'_, AppState>, pinned: bool) {
    *state.pinned.lock().unwrap() = pinned;
}

#[tauri::command]
fn set_config(app: AppHandle, config: Config) -> Config {
    let state = app.state::<AppState>();
    *state.config.lock().unwrap() = config;
    save_config(&state);
    let result = state.config.lock().unwrap().clone();
    result
}

/// Requires an http(s) scheme, adding `https://` when the user typed a bare
/// host. `open(1)` on macOS treats a bare host like `status.claude.com` as a
/// file path and pops the "Choose Application" picker when it can't match a
/// handler; `xdg-open` behaves similarly.
fn normalize_url(url: &str) -> Result<String, String> {
    let url = url.trim();
    if url.is_empty() {
        return Err("empty URL".into());
    }
    if url.starts_with("http://") || url.starts_with("https://") {
        Ok(url.to_string())
    } else if url.contains("://") {
        Err(format!("unsupported URL scheme: {url}"))
    } else {
        Ok(format!("https://{url}"))
    }
}

/// Hands a URL to the platform's default browser.
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    open::that(normalize_url(&url)?).map_err(|e| e.to_string())
}
