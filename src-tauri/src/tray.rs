use aistat_core::{aggregate, config::Config, model::SiteStatus, Status};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize};

use crate::state::{AppState, TrayAnchor};

/// Gap between the menu bar (or taskbar) and the panel, in logical pixels.
/// Native menu bar panels hang flush from the bar, so this is zero; the panel's
/// own rounded corners and shadow supply the visual separation.
const PANEL_GAP: f64 = 0.0;
/// Minimum distance the panel keeps from the edges of the screen.
const SCREEN_MARGIN: f64 = 8.0;
/// Panel metrics in logical pixels. The panel hugs its content between the
/// min and max; beyond the max it scrolls.
const PANEL_WIDTH: f64 = 348.0;
const PANEL_MIN_HEIGHT: f64 = 120.0;
const PANEL_MAX_HEIGHT: f64 = 520.0;
/// A tray click arriving within this window of the panel being hidden is the
/// same click that dismissed it, and must not re-open the panel.
const DISMISS_DEBOUNCE_MS: u128 = 250;

fn status_rgb(status: Status) -> (u8, u8, u8) {
    match status {
        Status::Operational => (0x2e, 0xc2, 0x7e),
        Status::Degraded => (0xf0, 0xc8, 0x32),
        Status::PartialOutage => (0xf5, 0x8a, 0x1f),
        Status::FullOutage => (0xe0, 0x3e, 0x3e),
        Status::Maintenance => (0x3b, 0x82, 0xf6),
        Status::Unknown => (0x9c, 0xa3, 0xaf),
    }
}

/// A rounded rectangle in the icon's unit square (0..1 on both axes).
struct RoundRect {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    r: f32,
}

impl RoundRect {
    fn contains(&self, x: f32, y: f32) -> bool {
        if x < self.x0 || x > self.x1 || y < self.y0 || y > self.y1 {
            return false;
        }
        // Nearest point on the inset core; the corner arcs sweep around it.
        // The inset can collapse when a side is narrower than the corner
        // diameter, so the upper bound is floored to keep clamp's range valid.
        let (ix0, iy0) = (self.x0 + self.r, self.y0 + self.r);
        let cx = x.clamp(ix0, (self.x1 - self.r).max(ix0));
        let cy = y.clamp(iy0, (self.y1 - self.r).max(iy0));
        let (dx, dy) = (x - cx, y - cy);
        dx * dx + dy * dy <= self.r * self.r
    }
}

fn disc(x: f32, y: f32, cx: f32, cy: f32, r: f32) -> bool {
    let (dx, dy) = (x - cx, y - cy);
    dx * dx + dy * dy <= r * r
}

/// True where the robot silhouette should be painted, for a point in the
/// icon's unit square: a rounded head, one antenna, and two knocked-out eyes.
///
/// Deliberately spare. At the 18pt the menu bar draws this, side ears and
/// closely-set eyes smear into the head, so the shape is carried by a big
/// silhouette with two well-separated cut-outs.
fn robot_mask(x: f32, y: f32) -> bool {
    const HEAD: RoundRect = RoundRect { x0: 0.11, y0: 0.24, x1: 0.89, y1: 0.86, r: 0.24 };
    const STALK: RoundRect = RoundRect { x0: 0.47, y0: 0.07, x1: 0.53, y1: 0.26, r: 0.03 };

    let body = HEAD.contains(x, y) || STALK.contains(x, y) || disc(x, y, 0.5, 0.08, 0.06);
    if !body {
        return false;
    }

    // Eyes are cut out of the head so the status color reads as the robot.
    let eyes = disc(x, y, 0.335, 0.55, 0.12) || disc(x, y, 0.665, 0.55, 0.12);
    !eyes
}

/// Renders the status-colored robot used as the menu bar icon.
///
/// macOS draws the status item image at 18pt tall, so 36px is pixel-exact on a
/// 2x display. Coverage is estimated with 4x4 supersampling to keep the curves
/// smooth at that size.
pub fn make_icon(status: Status) -> tauri::image::Image<'static> {
    let (r, g, b) = status_rgb(status);

    const SIZE: u32 = 36;
    const SS: u32 = 4;

    let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];

    for y in 0..SIZE {
        for x in 0..SIZE {
            let mut covered = 0u32;
            for sy in 0..SS {
                for sx in 0..SS {
                    let px = (x as f32 + (sx as f32 + 0.5) / SS as f32) / SIZE as f32;
                    let py = (y as f32 + (sy as f32 + 0.5) / SS as f32) / SIZE as f32;
                    if robot_mask(px, py) {
                        covered += 1;
                    }
                }
            }
            if covered == 0 {
                continue;
            }
            let alpha = (covered as f32 / (SS * SS) as f32 * 255.0).round() as u8;
            let i = ((y * SIZE + x) * 4) as usize;
            rgba[i] = r;
            rgba[i + 1] = g;
            rgba[i + 2] = b;
            rgba[i + 3] = alpha;
        }
    }

    tauri::image::Image::new_owned(rgba, SIZE, SIZE)
}

pub fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let refresh = MenuItem::with_id(app, "refresh", "Refresh Now", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit = PredefinedMenuItem::quit(app, None)?;
    let menu = Menu::with_items(app, &[&refresh, &settings, &separator, &quit])?;

    TrayIconBuilder::with_id("main")
        .icon(make_icon(Status::Unknown))
        .icon_as_template(false)
        .menu(&menu)
        .tooltip("AIStat")
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "refresh" => {
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    super::refresh_once(&handle).await;
                });
            }
            "settings" => {
                show_panel(app);
                let _ = app.emit("open-settings", ());
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            let app = tray.app_handle();
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                remember_anchor(app, &rect);
                toggle_panel(app);
            }
        })
        .build(app)?;

    Ok(())
}

/// Records where the tray icon currently sits so the panel can be anchored to
/// it. The rect moves whenever the user rearranges their menu bar.
fn remember_anchor(app: &AppHandle, rect: &tauri::Rect) {
    let scale = app
        .get_webview_window("main")
        .and_then(|w| w.scale_factor().ok())
        .unwrap_or(1.0);
    let position = rect.position.to_physical::<f64>(scale);
    let size = rect.size.to_physical::<f64>(scale);

    if size.width <= 0.0 || size.height <= 0.0 {
        return;
    }

    *app.state::<AppState>().tray_anchor.lock().unwrap() = Some(TrayAnchor {
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height,
    });
}

pub fn update_tray(app: &AppHandle, statuses: &[SiteStatus], config: &Config) {
    let overall = aggregate(statuses.iter().map(|s| s.overall), &config.status_priority);

    let tooltip = tooltip_text(statuses, overall);

    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(make_icon(overall)));
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

fn tooltip_text(statuses: &[SiteStatus], overall: Status) -> String {
    let mut lines = vec![format!("AIStat — {}", overall.label())];
    for s in statuses {
        lines.push(format!("{}: {}", s.name, s.overall.label()));
    }
    lines.join("\n")
}

/// Marks the panel as just-dismissed so the tray click that caused the blur
/// does not immediately re-open it.
pub fn note_panel_hidden(app: &AppHandle) {
    *app.state::<AppState>().hidden_at.lock().unwrap() = Some(std::time::Instant::now());
}

fn toggle_panel(app: &AppHandle) {
    // The click that dismissed the panel by blurring it also lands here.
    let state = app.state::<AppState>();
    let just_dismissed = match state.hidden_at.lock().unwrap().take() {
        Some(at) => at.elapsed().as_millis() < DISMISS_DEBOUNCE_MS,
        None => false,
    };
    if just_dismissed {
        return;
    }

    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        note_panel_hidden(app);
    } else {
        show_panel(app);
    }
}

pub fn show_panel(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let anchor = *app.state::<AppState>().tray_anchor.lock().unwrap();
    let size = window.outer_size().unwrap_or(PhysicalSize::new(380, 520));
    position_panel(&window, anchor, size);
    let _ = window.show();
    let _ = window.set_focus();
}

/// Grows or shrinks the panel to fit its content, then re-anchors it. Content
/// taller than [`PANEL_MAX_HEIGHT`] scrolls inside the panel instead.
pub fn resize_panel(app: &AppHandle, content_height: f64) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let height = content_height
        .ceil()
        .clamp(PANEL_MIN_HEIGHT, PANEL_MAX_HEIGHT);
    let scale = window.scale_factor().unwrap_or(1.0);

    let _ = window.set_size(LogicalSize::new(PANEL_WIDTH, height));

    // set_size is asynchronous on some platforms, so anchor against the size we
    // just asked for rather than re-reading it.
    let size = PhysicalSize::new(
        (PANEL_WIDTH * scale).round() as u32,
        (height * scale).round() as u32,
    );
    let anchor = *app.state::<AppState>().tray_anchor.lock().unwrap();
    position_panel(&window, anchor, size);
}

/// Finds the display the tray icon sits on.
///
/// This scans [`available_monitors`] rather than calling `monitor_from_point`:
/// that helper resolves the point against `CGDisplayBounds`, which is measured
/// in points, while every other monitor coordinate Tauri hands back is
/// physical. Feeding it physical coordinates on a Retina display silently
/// misses, and the fallback monitor's clamp then drags the panel onto the
/// wrong screen.
///
/// [`available_monitors`]: tauri::WebviewWindow::available_monitors
fn monitor_containing(window: &tauri::WebviewWindow, x: f64, y: f64) -> Option<tauri::Monitor> {
    let monitors = window.available_monitors().ok()?;
    monitors
        .into_iter()
        .find(|m| {
            let (pos, size) = (m.position(), m.size());
            x >= pos.x as f64
                && x < (pos.x + size.width as i32) as f64
                && y >= pos.y as f64
                && y < (pos.y + size.height as i32) as f64
        })
        .or_else(|| window.current_monitor().ok().flatten())
}

/// Places the panel directly under (or above, when there is no room below) the
/// tray icon, clamped to the usable area of the screen the icon lives on.
fn position_panel(
    window: &tauri::WebviewWindow,
    anchor: Option<TrayAnchor>,
    size: PhysicalSize<u32>,
) {
    let scale = window.scale_factor().unwrap_or(1.0);
    let gap = PANEL_GAP * scale;
    let margin = SCREEN_MARGIN * scale;
    let (w, h) = (size.width as f64, size.height as f64);

    let monitor = match anchor {
        Some(a) => monitor_containing(window, a.x + a.width / 2.0, a.y + a.height / 2.0),
        None => window.current_monitor().ok().flatten(),
    };
    let Some(monitor) = monitor else {
        return;
    };

    // The work area excludes the menu bar and the Dock, so its top edge *is*
    // the menu bar's bottom edge — the line a menu bar panel hangs from.
    let work = monitor.work_area();
    let area = Area {
        x: work.position.x as f64,
        y: work.position.y as f64,
        w: work.size.width as f64,
        h: work.size.height as f64,
    };

    let (x, y) = panel_origin(anchor, area, w, h, gap, margin);
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

/// A monitor's usable region, in physical pixels.
#[derive(Debug, Clone, Copy)]
struct Area {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Area {
    fn right(&self) -> f64 {
        self.x + self.w
    }
    fn bottom(&self) -> f64 {
        self.y + self.h
    }
}

/// Where the panel's top-left corner belongs, in physical pixels.
///
/// Split out from [`position_panel`] so the geometry can be tested without a
/// window or a second display attached.
fn panel_origin(
    anchor: Option<TrayAnchor>,
    area: Area,
    w: f64,
    h: f64,
    gap: f64,
    margin: f64,
) -> (f64, f64) {
    let (left, top) = match anchor {
        Some(anchor) => {
            let x = anchor.x + anchor.width / 2.0 - w / 2.0;

            // Hang from the menu bar rather than from the icon's own rect: the
            // reported rect is a little taller than the menu bar and its height
            // is not stable between runs, which showed up as the panel sitting
            // a few points too low.
            let below = (anchor.y + anchor.height).max(area.y) + gap;
            // Flip above the icon when there is no room below, as on a default
            // Windows setup where the tray sits on the bottom edge.
            let y = if below + h > area.bottom() {
                anchor.y.min(area.bottom()) - gap - h
            } else {
                below
            };
            (x, y)
        }
        // No anchor yet (opened from the tray menu before any icon click).
        None => (area.right() - w - margin, area.y + gap),
    };

    let min_x = area.x + margin;
    let max_x = area.right() - w - margin;
    let min_y = area.y;
    let max_y = area.bottom() - h;

    (
        left.clamp(min_x, max_x.max(min_x)),
        top.clamp(min_y, max_y.max(min_y)),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A rect narrower than its corner diameter used to make `clamp` panic
    /// with `min > max`, which crashed icon rendering at startup.
    #[test]
    fn thin_rounded_rects_do_not_panic() {
        let thin = RoundRect { x0: 0.475, y0: 0.10, x1: 0.525, y1: 0.32, r: 0.025 };
        for i in 0..=100 {
            let v = i as f32 / 100.0;
            thin.contains(v, v);
            thin.contains(0.5, v);
        }
        assert!(thin.contains(0.5, 0.2));
        assert!(!thin.contains(0.1, 0.2));
    }

    #[test]
    fn robot_has_a_head_antenna_and_cut_out_eyes() {
        assert!(robot_mask(0.5, 0.75), "center of the head is filled");
        assert!(robot_mask(0.5, 0.08), "antenna tip is filled");
        assert!(robot_mask(0.5, 0.20), "antenna stalk is filled");
        assert!(!robot_mask(0.335, 0.55), "left eye is knocked out");
        assert!(!robot_mask(0.665, 0.55), "right eye is knocked out");
        assert!(robot_mask(0.5, 0.55), "the bridge between the eyes stays solid");
        assert!(!robot_mask(0.02, 0.02), "corners stay transparent");
    }

    /// Ears were dropped because they smeared into the head at menu bar size.
    #[test]
    fn robot_has_no_side_ears() {
        for y in [0.45, 0.55, 0.65] {
            assert!(!robot_mask(0.05, y), "left of the head is empty at y={y}");
            assert!(!robot_mask(0.95, y), "right of the head is empty at y={y}");
        }
    }

    #[test]
    fn icon_is_the_expected_size_and_partly_opaque() {
        for status in [Status::Operational, Status::FullOutage, Status::Unknown] {
            let img = make_icon(status);
            assert_eq!((img.width(), img.height()), (36, 36));

            let rgba = img.rgba();
            assert_eq!(rgba.len(), 36 * 36 * 4);
            let opaque = rgba.chunks(4).filter(|px| px[3] > 200).count();
            let clear = rgba.chunks(4).filter(|px| px[3] == 0).count();
            assert!(opaque > 200, "robot should cover a good chunk: {opaque}");
            assert!(clear > 200, "and leave transparent margins: {clear}");
        }
    }

    /// The MacBook display measured on this machine: it sits below an external
    /// screen, so its origin is non-zero, and its notched menu bar is 66px tall
    /// while the tray icon's own rect is a different height again.
    const LAPTOP: Area = Area { x: 524.0, y: 2370.0, w: 3024.0, h: 1810.0 };
    const ICON: TrayAnchor = TrayAnchor { x: 2456.0, y: 2304.0, width: 48.0, height: 66.0 };

    fn origin(anchor: Option<TrayAnchor>, area: Area, h: f64) -> (f64, f64) {
        panel_origin(anchor, area, 696.0, h, PANEL_GAP, SCREEN_MARGIN * 2.0)
    }

    /// The reported icon rect is taller than the menu bar, so anchoring to it
    /// left the panel a few points low. It must hang off the work area's top.
    #[test]
    fn panel_top_sits_flush_under_the_menu_bar() {
        let (_, y) = origin(Some(ICON), LAPTOP, 400.0);
        assert_eq!(y, LAPTOP.y);
    }

    /// Growing the panel must not move its top edge.
    #[test]
    fn panel_top_is_independent_of_height() {
        let tops: Vec<f64> = [400.0, 680.0, 1040.0]
            .iter()
            .map(|h| origin(Some(ICON), LAPTOP, *h).1)
            .collect();
        assert_eq!(tops, vec![LAPTOP.y; 3]);
    }

    #[test]
    fn panel_is_centered_under_the_icon() {
        let (x, _) = origin(Some(ICON), LAPTOP, 400.0);
        assert_eq!(x + 696.0 / 2.0, ICON.x + ICON.width / 2.0);
    }

    /// An icon near the right edge would push the panel off screen.
    #[test]
    fn panel_stays_inside_the_work_area() {
        let edge = TrayAnchor { x: LAPTOP.right() - 48.0, ..ICON };
        let (x, _) = origin(Some(edge), LAPTOP, 400.0);
        assert!(x + 696.0 <= LAPTOP.right(), "x={x} overflows the screen");
        assert!(x >= LAPTOP.x);
    }

    /// A tray on the bottom edge (the Windows default) opens upward.
    #[test]
    fn panel_flips_above_a_bottom_edge_tray() {
        let taskbar = Area { x: 0.0, y: 0.0, w: 1920.0, h: 1040.0 };
        let icon = TrayAnchor { x: 1800.0, y: 1040.0, width: 32.0, height: 40.0 };
        let (_, y) = origin(Some(icon), taskbar, 400.0);
        assert_eq!(y + 400.0, icon.y, "panel should end where the taskbar starts");
    }

    /// Taller than the screen: pinned to the top rather than pushed off it.
    #[test]
    fn oversized_panel_pins_to_the_top() {
        let (_, y) = origin(Some(ICON), LAPTOP, LAPTOP.h + 500.0);
        assert_eq!(y, LAPTOP.y);
    }

    #[test]
    fn without_an_anchor_the_panel_tucks_into_the_top_right() {
        let (x, y) = origin(None, LAPTOP, 400.0);
        assert!(x + 696.0 <= LAPTOP.right());
        assert_eq!(y, LAPTOP.y);
    }

    #[test]
    fn each_status_gets_its_own_color() {
        let colors: std::collections::HashSet<_> = Status::DEFAULT_PRIORITY
            .iter()
            .map(|s| status_rgb(*s))
            .collect();
        assert_eq!(colors.len(), Status::DEFAULT_PRIORITY.len());
    }
}

