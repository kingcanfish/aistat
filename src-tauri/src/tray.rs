use aiisdown_core::{aggregate, config::Config, model::SiteStatus, Status};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize};

/// Renders a solid circular dot in the status color as a tray/menu bar icon.
pub fn make_icon(status: Status) -> tauri::image::Image<'static> {
    let (r, g, b) = match status {
        Status::Operational => (0x2e, 0xc2, 0x7e),
        Status::Degraded => (0xf0, 0xc8, 0x32),
        Status::PartialOutage => (0xf5, 0x8a, 0x1f),
        Status::FullOutage => (0xe0, 0x3e, 0x3e),
        Status::Maintenance => (0x3b, 0x82, 0xf6),
        Status::Unknown => (0x9c, 0xa3, 0xaf),
    };

    let size: u32 = 32;
    let center = size as f32 / 2.0;
    let radius = size as f32 * 0.42;
    let mut rgba = vec![0u8; (size * size * 4) as usize];

    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 + 0.5 - center;
            let dy = y as f32 + 0.5 - center;
            if (dx * dx + dy * dy).sqrt() <= radius {
                let i = ((y * size + x) * 4) as usize;
                rgba[i] = r;
                rgba[i + 1] = g;
                rgba[i + 2] = b;
                rgba[i + 3] = 255;
            }
        }
    }

    tauri::image::Image::new_owned(rgba, size, size)
}

pub fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let toggle = MenuItem::with_id(app, "toggle", "Show/Hide Panel", true, None::<&str>)?;
    let refresh = MenuItem::with_id(app, "refresh", "Refresh Now", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit = PredefinedMenuItem::quit(app, None)?;
    let menu = Menu::with_items(app, &[&toggle, &refresh, &separator, &quit])?;

    TrayIconBuilder::with_id("main")
        .icon(make_icon(Status::Unknown))
        .menu(&menu)
        .tooltip("AI Status")
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "toggle" => toggle_window(app),
            "refresh" => {
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    super::refresh_once(&handle).await;
                });
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                toggle_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}

pub fn update_tray(app: &AppHandle, statuses: &[SiteStatus], config: &Config) {
    let overall = aggregate(
        statuses.iter().map(|s| s.overall),
        &config.status_priority,
    );

    let tooltip = tooltip_text(statuses, overall);

    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(make_icon(overall)));
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

fn tooltip_text(statuses: &[SiteStatus], overall: Status) -> String {
    let mut lines = vec![format!("AI Status — {}", overall.label())];
    for s in statuses {
        lines.push(format!("{}: {}", s.name, s.overall.label()));
    }
    lines.join("\n")
}

fn toggle_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
        } else {
            position_panel(&window);
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

fn position_panel(window: &tauri::WebviewWindow) {
    if let Ok(Some(monitor)) = window.current_monitor() {
        let size = window
            .outer_size()
            .unwrap_or(PhysicalSize::new(380, 540));
        let msize = monitor.size();
        let mpos = monitor.position();
        let x = mpos.x + msize.width as i32 - size.width as i32 - 8;
        let y = mpos.y + 28;
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}
