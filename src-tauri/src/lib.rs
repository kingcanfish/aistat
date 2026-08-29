mod appearance;
mod state;
mod tray;

use std::collections::HashMap;

use aistat_core::{
    config::Config, config::SiteConfig, detect_changes, fetch_all, model::SiteStatus, HttpClient,
};
use state::AppState;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tray::update_tray;

/// Sends log output to stderr, which is the terminal when the app is started
/// from one and the unified log otherwise.
///
/// Warnings and errors are on by default so a user who reruns the app from a
/// terminal to find out why a row is stuck on "Unknown" gets an answer without
/// having to know an env var exists. `AISTAT_LOG` turns the volume up:
/// `AISTAT_LOG=debug` also traces icon lookups and rustls handshakes.
fn init_logging() {
    env_logger::Builder::from_env(
        // `aistat_lib` rather than `aistat`: log targets are module paths, and
        // this crate's [lib] name is what lands at the root of ours.
        env_logger::Env::new().filter_or("AISTAT_LOG", "warn,aistat_lib=info,aistat_core=info"),
    )
    .format_timestamp_secs()
    .init();
}

pub fn run() {
    init_logging();

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
        .on_window_event(|window, event| match event {
            // Native menu bar panels dismiss as soon as they lose focus.
            WindowEvent::Focused(false) => {
                let app = window.app_handle();
                let pinned = *app.state::<AppState>().pinned.lock().unwrap();
                if window.label() == "main" && !pinned {
                    let _ = window.hide();
                    tray::note_panel_hidden(app);
                }
            }
            // The icon is drawn in the menu bar's own label colour, so it has
            // to be redrawn when the user switches appearance — nothing else
            // repaints it, and a stale icon is a black glyph on a black bar.
            WindowEvent::ThemeChanged(_) => {
                let app = window.app_handle();
                let state = app.state::<AppState>();
                let statuses = state.statuses.lock().unwrap().clone();
                let config = state.config.lock().unwrap().clone();
                update_tray(app, &statuses, &config);
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            get_statuses,
            refresh_now,
            get_config,
            set_config,
            open_url,
            set_panel_pinned,
            detect_adapter,
            resize_panel,
            app_version
        ])
        .run(tauri::generate_context!())
        .expect("error while running aistat");
}

fn load_config(path: &std::path::Path) -> Config {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        // A missing file is the first run, not a problem worth a warning.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            log::info!("no config at {}, starting from defaults", path.display());
            return Config::default();
        }
        Err(e) => {
            log::error!(
                "could not read {}: {e}; starting from defaults",
                path.display()
            );
            return Config::default();
        }
    };

    // A hand-edited config that fails to parse silently reverts to defaults,
    // which looks exactly like the app ignoring the file. Say so.
    match Config::from_json(&text) {
        Ok(config) => config,
        Err(e) => {
            log::error!(
                "{} is not valid config JSON: {e}; starting from defaults",
                path.display()
            );
            Config::default()
        }
    }
}

fn save_config(state: &AppState) {
    let json = match state.config.lock().unwrap().to_json() {
        Ok(json) => json,
        Err(e) => {
            log::error!("could not serialize config: {e}");
            return;
        }
    };
    if let Err(e) = std::fs::write(&state.config_path, json) {
        log::error!("could not write {}: {e}", state.config_path.display());
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
    let started = std::time::Instant::now();
    let (mut statuses, ()) = futures::future::join(
        fetch_all(&client, &config.sites),
        resolve_icons(app, &client, &config.sites),
    )
    .await;
    apply_icons(app, &mut statuses);

    // Per-site failures are logged where they happen; this is the one line
    // that says a refresh ran at all, and how many sites came back unreadable.
    let failed = statuses.iter().filter(|s| s.error.is_some()).count();
    log::info!(
        "refreshed {} site(s) in {}ms, {failed} failed",
        statuses.len(),
        started.elapsed().as_millis()
    );

    let changes = {
        let previous = state.previous.lock().unwrap();
        detect_changes(&previous, &statuses)
    };

    {
        let mut previous = state.previous.lock().unwrap();
        *previous = statuses.iter().map(|s| (s.id.clone(), s.clone())).collect();
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

    let resolved =
        futures::future::join_all(unresolved.into_iter().map(|url: String| async move {
            let icon = aistat_core::providers::icon::fetch_icon_url(client, &url).await;
            (url, icon)
        }))
        .await;

    app.state::<AppState>()
        .icons
        .lock()
        .unwrap()
        .extend(resolved);
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
            let seconds = state
                .config
                .lock()
                .unwrap()
                .refresh_interval_seconds
                .max(30);
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
    if let Err(e) = notify_rust::Notification::new()
        .summary(&summary)
        .body(&body)
        .show()
    {
        log::warn!(
            "could not post a notification for {}: {e}",
            change.site_name
        );
    }
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

/// The bundled version, so the settings footer can show what is running
/// without the UI keeping its own copy of the number to fall out of date.
#[tauri::command]
fn app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Hands a URL to the platform's default browser.
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    open::that(normalize_url(&url)?).map_err(|e| {
        log::warn!("could not open {url} in a browser: {e}");
        e.to_string()
    })
}
