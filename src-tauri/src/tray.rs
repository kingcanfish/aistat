use aistat_core::{aggregate, config::Config, model::SiteStatus, IconStyle, Status};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize};

use crate::appearance;
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

/// Status colours, in a light-bar and a dark-bar variant.
///
/// Not a third palette: the dark column is the panel's `--dot-*` lamps and the
/// light column its contrast-tuned `--green`/`--yellow`/… set, both taken from
/// `ui/style.css`, and each from that stylesheet's own block for the matching
/// appearance — the panel declares the `--dot-*` lamps twice, and it is the
/// *dark* block's values that belong on a dark menu bar.
///
/// One set cannot serve both bars: a lamp tuned for a dark surface loses most
/// of its contrast on a light one, which is the actual reason the old
/// operational green disappeared there.
fn status_rgb(status: Status, dark: bool) -> (u8, u8, u8) {
    match (status, dark) {
        (Status::Operational, false) => (0x1a, 0x8a, 0x52),
        (Status::Operational, true) => (0x30, 0xd1, 0x58),
        (Status::Degraded, false) => (0xb0, 0x7d, 0x05),
        (Status::Degraded, true) => (0xff, 0xd6, 0x0a),
        (Status::PartialOutage, false) => (0xcc, 0x65, 0x10),
        (Status::PartialOutage, true) => (0xff, 0x9f, 0x0a),
        (Status::FullOutage, false) => (0xc6, 0x2f, 0x2f),
        (Status::FullOutage, true) => (0xff, 0x45, 0x3a),
        (Status::Maintenance, false) => (0x25, 0x63, 0xeb),
        (Status::Maintenance, true) => (0x0a, 0x84, 0xff),
        (Status::Unknown, false) => (0x86, 0x86, 0x8b),
        (Status::Unknown, true) => (0x98, 0x98, 0x9d),
    }
}

/// What AppKit would tint a template image: the menu bar's label colour.
fn label_rgb(dark: bool) -> (u8, u8, u8) {
    if dark {
        (0xff, 0xff, 0xff)
    } else {
        (0x00, 0x00, 0x00)
    }
}

/// The menu bar draws the status item image 18 pt tall, so the geometry below
/// is written in those points and rasterised at 2 px per point — pixel-exact
/// on a 2x display, and readable against the design's own measurements.
const ICON_PT: f32 = 18.0;
const ICON_PX: u32 = 36;

const HEAD: RoundRect = RoundRect {
    x0: 2.4,
    y0: 5.4,
    x1: 15.6,
    y1: 16.6,
    r: 4.0,
};
const EYE_L: (f32, f32) = (6.5, 10.5);
const EYE_R: (f32, f32) = (11.5, 10.5);
/// Tucked inside the head's outer edge rather than hung off the corner: a
/// lamp that stuck out would make the icon's extent change with the status,
/// which reads as the mark resizing every time a service wobbles.
const LAMP: (f32, f32) = (14.0, 14.0);
const LAMP_R: f32 = 2.4;
/// The lamp is punched out of the glyph rather than drawn over it, so the two
/// never share a pixel and the lamp keeps its full chroma at 5 pt.
const LAMP_KNOCKOUT: f32 = LAMP_R + 1.1;

/// How loud the mark is allowed to be. The silhouette is identical in all
/// three — only the ink changes, so it never stops being the same icon.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Weight {
    /// Monochrome glyph, status in the corner lamp.
    Calm,
    /// The glyph itself in the status colour, on a slightly heavier stroke.
    Tinted,
    /// Head filled, eyes knocked out.
    Filled,
}

/// Maps a status onto a weight for the user's chosen style.
///
/// The escalation is the whole argument for the default: a 5 pt lamp is 7% of
/// the icon, which peripheral vision cannot resolve, whereas the difference
/// between an outline and a solid block survives being out of focus. So the
/// glance decision becomes "is there any colour at all", not "which hue is
/// that dot" — and the bar stays monochrome on an ordinary day.
fn weight_for(style: IconStyle, status: Status) -> Weight {
    match style {
        IconStyle::Lamp => Weight::Calm,
        IconStyle::Tinted => Weight::Tinted,
        IconStyle::Escalating => match status {
            Status::Operational | Status::Unknown => Weight::Calm,
            Status::Degraded | Status::Maintenance => Weight::Tinted,
            Status::PartialOutage | Status::FullOutage => Weight::Filled,
        },
    }
}

/// A rounded rectangle in icon points.
struct RoundRect {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    r: f32,
}

impl RoundRect {
    /// Signed distance to the edge — negative inside, positive outside.
    ///
    /// A distance rather than a boolean because two of the three weights
    /// *stroke* this shape, and a stroke is just the band where the distance
    /// is within half the pen width. Degenerate rectangles (a side narrower
    /// than the corner diameter, as the stalk nearly is) fall out correctly
    /// instead of needing a special case, which is what the old
    /// `clamp`-based containment test kept getting wrong.
    fn distance(&self, x: f32, y: f32) -> f32 {
        let (cx, cy) = ((self.x0 + self.x1) / 2.0, (self.y0 + self.y1) / 2.0);
        let (hx, hy) = ((self.x1 - self.x0) / 2.0, (self.y1 - self.y0) / 2.0);
        let qx = (x - cx).abs() - (hx - self.r);
        let qy = (y - cy).abs() - (hy - self.r);
        let outside = (qx.max(0.0) * qx.max(0.0) + qy.max(0.0) * qy.max(0.0)).sqrt();
        outside + qx.max(qy).min(0.0) - self.r
    }
}

fn disc_distance(x: f32, y: f32, c: (f32, f32)) -> f32 {
    let (dx, dy) = (x - c.0, y - c.1);
    (dx * dx + dy * dy).sqrt()
}

/// Distance to a line segment, for the antenna's centre line.
fn segment_distance(x: f32, y: f32, a: (f32, f32), b: (f32, f32)) -> f32 {
    let (vx, vy) = (b.0 - a.0, b.1 - a.1);
    let (wx, wy) = (x - a.0, y - a.1);
    let len2 = vx * vx + vy * vy;
    let t = if len2 == 0.0 {
        0.0
    } else {
        ((wx * vx + wy * vy) / len2).clamp(0.0, 1.0)
    };
    let (dx, dy) = (wx - vx * t, wy - vy * t);
    (dx * dx + dy * dy).sqrt()
}

/// Which of the two ink layers, if either, covers this point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Layer {
    None,
    Glyph,
    Lamp,
}

fn layer_at(x: f32, y: f32, weight: Weight) -> Layer {
    if weight == Weight::Calm {
        let d = disc_distance(x, y, LAMP);
        if d <= LAMP_R {
            return Layer::Lamp;
        }
        if d <= LAMP_KNOCKOUT {
            return Layer::None;
        }
    }

    let inked = match weight {
        Weight::Calm | Weight::Tinted => {
            // Stroked, open form — the reason this reads as a menu bar glyph
            // and not as a piece of app chrome that wandered up there.
            let (pen, tip_r, eye_r, antenna_top) = if weight == Weight::Calm {
                (1.4, 1.05, 1.15, 3.5)
            } else {
                (1.6, 1.2, 1.25, 3.4)
            };
            let half = pen / 2.0;
            HEAD.distance(x, y).abs() <= half
                || segment_distance(x, y, (9.0, antenna_top), (9.0, 5.4)) <= half
                || disc_distance(x, y, (9.0, 2.45)) <= tip_r
                || disc_distance(x, y, EYE_L) <= eye_r
                || disc_distance(x, y, EYE_R) <= eye_r
        }
        Weight::Filled => {
            // The calm weight's shapes exactly, with the head *filled* rather
            // than stroked: `<= 0.7` reaches the same outer edge the 1.4 pt
            // pen does, so the silhouette does not move when the status does.
            let body = HEAD.distance(x, y) <= 0.7
                || segment_distance(x, y, (9.0, 3.5), (9.0, 5.4)) <= 0.7
                || disc_distance(x, y, (9.0, 2.45)) <= 1.05;
            body && disc_distance(x, y, EYE_L) > 1.55 && disc_distance(x, y, EYE_R) > 1.55
        }
    };

    if inked {
        Layer::Glyph
    } else {
        Layer::None
    }
}

/// Renders the menu bar icon for a status, in the user's chosen style and for
/// the current menu bar appearance.
///
/// Coverage is estimated with 4x4 supersampling: at 36 px the curves and the
/// 2.8 px strokes both land off the pixel grid, and snapping either to it
/// would make the mark read heavier than the Apple glyphs beside it.
pub fn make_icon(status: Status, style: IconStyle, dark: bool) -> tauri::image::Image<'static> {
    let weight = weight_for(style, status);
    let lamp = status_rgb(status, dark);
    let glyph = if weight == Weight::Calm {
        label_rgb(dark)
    } else {
        lamp
    };
    // Unknown is a missing answer, not an alarm, so it stays half-present
    // rather than sitting in the bar at full strength like a real state.
    let fade = if status == Status::Unknown && weight == Weight::Calm {
        0.55
    } else {
        1.0
    };

    const SS: u32 = 4;
    let mut rgba = vec![0u8; (ICON_PX * ICON_PX * 4) as usize];

    for y in 0..ICON_PX {
        for x in 0..ICON_PX {
            let (mut glyph_cov, mut lamp_cov) = (0u32, 0u32);
            for sy in 0..SS {
                for sx in 0..SS {
                    let px = (x as f32 + (sx as f32 + 0.5) / SS as f32) / ICON_PX as f32 * ICON_PT;
                    let py = (y as f32 + (sy as f32 + 0.5) / SS as f32) / ICON_PX as f32 * ICON_PT;
                    match layer_at(px, py, weight) {
                        Layer::Glyph => glyph_cov += 1,
                        Layer::Lamp => lamp_cov += 1,
                        Layer::None => {}
                    }
                }
            }
            let covered = glyph_cov + lamp_cov;
            if covered == 0 {
                continue;
            }
            // Straight (non-premultiplied) alpha, so the two layers blend by
            // their share of the pixel before the alpha is applied.
            let mix = |a: u8, b: u8| {
                ((a as f32 * glyph_cov as f32 + b as f32 * lamp_cov as f32) / covered as f32)
                    .round() as u8
            };
            let alpha = (covered as f32 / (SS * SS) as f32 * 255.0 * fade).round() as u8;
            let i = ((y * ICON_PX + x) * 4) as usize;
            rgba[i] = mix(glyph.0, lamp.0);
            rgba[i + 1] = mix(glyph.1, lamp.1);
            rgba[i + 2] = mix(glyph.2, lamp.2);
            rgba[i + 3] = alpha;
        }
    }

    tauri::image::Image::new_owned(rgba, ICON_PX, ICON_PX)
}

pub fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let refresh = MenuItem::with_id(app, "refresh", "Refresh Now", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit = PredefinedMenuItem::quit(app, None)?;
    let menu = Menu::with_items(app, &[&refresh, &settings, &separator, &quit])?;

    TrayIconBuilder::with_id("main")
        .icon(make_icon(
            Status::Unknown,
            IconStyle::default(),
            appearance::menu_bar_is_dark(),
        ))
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

    // Watch the menu bar for the rest of the process. Registering with
    // `Initial` makes this deliver the current value straight away, which is
    // also the fix for the startup case: the probe's button reports the *app*
    // appearance until AppKit installs it in the bar, and that installation is
    // itself a change KVO delivers a moment later.
    let handle = app.handle().clone();
    appearance::observe(move || redraw_icon(&handle));

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
        let _ = tray.set_icon(Some(make_icon(
            overall,
            config.icon_style,
            appearance::menu_bar_is_dark(),
        )));
        let _ = tray.set_tooltip(Some(tooltip));
    }

    // Belt and braces. The KVO observer set up in `setup_tray` is what
    // actually keeps the icon in step; this only catches the case where that
    // registration never took, and costs one string read per refresh.
    resync_appearance(app);
}

/// Re-reads the menu bar's appearance and redraws the icon if it moved.
///
/// Hops to the main thread because AppKit will only answer there. Not the
/// primary mechanism — see the observer in [`setup_tray`] — and it does
/// nothing at all in the ordinary case where the answer has not changed.
pub fn resync_appearance(app: &AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if appearance::resample() {
            redraw_icon(&handle);
        }
    });
}

/// Redraws the tray icon for the state the app is already in. Called by the
/// appearance observer, which has no opinion about status — only about ink.
fn redraw_icon(app: &AppHandle) {
    let Some(tray) = app.tray_by_id("main") else {
        return;
    };
    let state = app.state::<AppState>();
    let statuses = state.statuses.lock().unwrap().clone();
    let config = state.config.lock().unwrap().clone();
    let overall = aggregate(statuses.iter().map(|s| s.overall), &config.status_priority);
    let dark = appearance::menu_bar_is_dark();
    let _ = tray.set_icon(Some(make_icon(overall, config.icon_style, dark)));
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
///
/// Deliberately silent towards the UI: anything the panel needs to reset on
/// the way out has to happen before the window is hidden, because a hidden
/// window's webview stops servicing frames. The UI hangs that off its own
/// `blur` event instead.
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

    /// Pixels of the 36px icon, as (r, g, b, a).
    fn pixels(status: Status, style: IconStyle, dark: bool) -> Vec<(u8, u8, u8, u8)> {
        make_icon(status, style, dark)
            .rgba()
            .chunks(4)
            .map(|px| (px[0], px[1], px[2], px[3]))
            .collect()
    }

    /// Points, as the geometry is written, converted to a pixel index.
    fn at(px: &[(u8, u8, u8, u8)], x: u32, y: u32) -> (u8, u8, u8, u8) {
        px[(y * ICON_PX + x) as usize]
    }

    const ON_HEAD_STROKE: (u32, u32) = (5, 22);
    const INSIDE_HEAD: (u32, u32) = (18, 24);
    const ON_LEFT_EYE: (u32, u32) = (13, 21);
    /// Well inside the lamp disc and clear of the head outline, so it reads
    /// the lamp alone in the calm weight and nothing at all in the others.
    const ON_LAMP: (u32, u32) = (26, 26);

    #[test]
    fn icon_is_the_expected_size_and_partly_opaque() {
        for style in [IconStyle::Escalating, IconStyle::Lamp, IconStyle::Tinted] {
            for status in Status::DEFAULT_PRIORITY {
                for dark in [false, true] {
                    let img = make_icon(status, style, dark);
                    assert_eq!((img.width(), img.height()), (36, 36));

                    let rgba = img.rgba();
                    assert_eq!(rgba.len(), 36 * 36 * 4);
                    let opaque = rgba.chunks(4).filter(|px| px[3] > 120).count();
                    let clear = rgba.chunks(4).filter(|px| px[3] == 0).count();
                    assert!(
                        opaque > 120,
                        "{style:?}/{status:?}: too little ink: {opaque}"
                    );
                    assert!(clear > 400, "{style:?}/{status:?}: no margins: {clear}");
                }
            }
        }
    }

    /// The calm weight is the one that has to look native: monochrome glyph in
    /// the label colour, with every bit of hue confined to the lamp.
    #[test]
    fn the_calm_weight_keeps_the_glyph_monochrome() {
        let px = pixels(Status::Operational, IconStyle::Lamp, false);
        assert_eq!(at(&px, ON_HEAD_STROKE.0, ON_HEAD_STROKE.1), (0, 0, 0, 255));
        assert_eq!(at(&px, ON_LEFT_EYE.0, ON_LEFT_EYE.1), (0, 0, 0, 255));
        assert_eq!(at(&px, ON_LAMP.0, ON_LAMP.1), (0x1a, 0x8a, 0x52, 255));
        assert_eq!(
            at(&px, INSIDE_HEAD.0, INSIDE_HEAD.1).3,
            0,
            "the head is open"
        );
    }

    /// The whole point of carrying two palettes: on a dark bar the glyph goes
    /// white and the lamp moves to the brighter variant of the same hue.
    #[test]
    fn a_dark_menu_bar_flips_the_glyph_and_brightens_the_lamp() {
        let px = pixels(Status::Operational, IconStyle::Lamp, true);
        assert_eq!(
            at(&px, ON_HEAD_STROKE.0, ON_HEAD_STROKE.1),
            (0xff, 0xff, 0xff, 255)
        );
        assert_eq!(at(&px, ON_LAMP.0, ON_LAMP.1), (0x30, 0xd1, 0x58, 255));
    }

    /// The lamp is punched out of the glyph rather than laid over it, so the
    /// outline never shows through the 5 pt of colour that has to carry state.
    #[test]
    fn the_lamp_is_punched_out_of_the_glyph() {
        let mut crossings = 0;
        for i in 0..720 {
            let t = i as f32 / 720.0 * std::f32::consts::TAU;
            let (x, y) = (
                LAMP.0 + (LAMP_R + 0.4) * t.cos(),
                LAMP.1 + (LAMP_R + 0.4) * t.sin(),
            );
            if HEAD.distance(x, y).abs() <= 0.7 {
                assert_eq!(layer_at(x, y, Weight::Calm), Layer::None, "at {x}, {y}");
                crossings += 1;
            }
        }
        assert!(crossings > 0, "the ring should cross the head outline");
    }

    #[test]
    fn the_tinted_weight_colours_the_glyph_itself() {
        let px = pixels(Status::Degraded, IconStyle::Tinted, false);
        let ink = (0xb0, 0x7d, 0x05, 255);
        assert_eq!(at(&px, ON_HEAD_STROKE.0, ON_HEAD_STROKE.1), ink);
        assert_eq!(at(&px, ON_LEFT_EYE.0, ON_LEFT_EYE.1), ink);
        // The lamp is gone in this weight — the whole glyph carries the state,
        // so a second marker in the corner would only be noise.
        assert_eq!(at(&px, ON_LAMP.0, ON_LAMP.1).3, 0);
    }

    #[test]
    fn the_filled_weight_fills_the_head_and_leaves_the_eyes_open() {
        let px = pixels(Status::FullOutage, IconStyle::Escalating, false);
        assert_eq!(
            at(&px, INSIDE_HEAD.0, INSIDE_HEAD.1),
            (0xc6, 0x2f, 0x2f, 255)
        );
        assert_eq!(at(&px, ON_LEFT_EYE.0, ON_LEFT_EYE.1).3, 0, "eyes stay open");
    }

    /// Severity has to map onto weight, or the escalation is decoration.
    #[test]
    fn escalating_style_maps_severity_onto_weight() {
        use Status::*;
        for (status, want) in [
            (Operational, Weight::Calm),
            (Unknown, Weight::Calm),
            (Degraded, Weight::Tinted),
            (Maintenance, Weight::Tinted),
            (PartialOutage, Weight::Filled),
            (FullOutage, Weight::Filled),
        ] {
            assert_eq!(
                weight_for(IconStyle::Escalating, status),
                want,
                "{status:?}"
            );
        }
        // The other two styles are deliberately flat.
        for status in Status::DEFAULT_PRIORITY {
            assert_eq!(weight_for(IconStyle::Lamp, status), Weight::Calm);
            assert_eq!(weight_for(IconStyle::Tinted, status), Weight::Tinted);
        }
    }

    /// Only the ink is allowed to change between states — a mark that also
    /// changed size would read as a different icon appearing in the bar.
    #[test]
    fn the_silhouette_does_not_move_between_weights() {
        let bounds = |status, style| {
            let px = pixels(status, style, false);
            let (mut x0, mut y0, mut x1, mut y1) = (36u32, 36u32, 0u32, 0u32);
            for y in 0..36 {
                for x in 0..36 {
                    if at(&px, x, y).3 > 0 {
                        x0 = x0.min(x);
                        y0 = y0.min(y);
                        x1 = x1.max(x);
                        y1 = y1.max(y);
                    }
                }
            }
            (x0, y0, x1, y1)
        };
        let calm = bounds(Status::Operational, IconStyle::Escalating);
        // Filled is the calm shape with the head inked in, so it is exact.
        assert_eq!(bounds(Status::FullOutage, IconStyle::Escalating), calm);
        // Tinted carries a 1.6 pt pen rather than 1.4 — coloured ink at mid
        // luminance reads thinner than black on white, so it is compensated —
        // which is allowed to spill a single pixel and no more.
        let tinted = bounds(Status::Degraded, IconStyle::Escalating);
        for (a, b) in [
            (tinted.0, calm.0),
            (tinted.1, calm.1),
            (tinted.2, calm.2),
            (tinted.3, calm.3),
        ] {
            assert!(a.abs_diff(b) <= 1, "tinted {tinted:?} vs calm {calm:?}");
        }
    }

    /// The keyline the previous icon needed is gone, so the artwork has to
    /// keep its own clear space instead of leaning on the bitmap edge.
    #[test]
    fn nothing_touches_the_bitmap_edge() {
        for style in [IconStyle::Escalating, IconStyle::Lamp, IconStyle::Tinted] {
            for status in Status::DEFAULT_PRIORITY {
                let px = pixels(status, style, false);
                for i in 0..36 {
                    for (x, y) in [(i, 0), (i, 35), (0, i), (35, i)] {
                        assert_eq!(at(&px, x, y).3, 0, "{style:?}/{status:?} at {x},{y}");
                    }
                }
            }
        }
    }

    /// Unknown means "we could not ask", which is not news. It sits back.
    #[test]
    fn unknown_sits_back_from_the_other_states() {
        let unknown = pixels(Status::Unknown, IconStyle::Escalating, false);
        let healthy = pixels(Status::Operational, IconStyle::Escalating, false);
        let a = at(&unknown, ON_HEAD_STROKE.0, ON_HEAD_STROKE.1).3;
        let b = at(&healthy, ON_HEAD_STROKE.0, ON_HEAD_STROKE.1).3;
        assert!(
            a < b,
            "unknown ({a}) should be fainter than operational ({b})"
        );
    }

    /// The MacBook display measured on this machine: it sits below an external
    /// screen, so its origin is non-zero, and its notched menu bar is 66px tall
    /// while the tray icon's own rect is a different height again.
    const LAPTOP: Area = Area {
        x: 524.0,
        y: 2370.0,
        w: 3024.0,
        h: 1810.0,
    };
    const ICON: TrayAnchor = TrayAnchor {
        x: 2456.0,
        y: 2304.0,
        width: 48.0,
        height: 66.0,
    };

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
        let edge = TrayAnchor {
            x: LAPTOP.right() - 48.0,
            ..ICON
        };
        let (x, _) = origin(Some(edge), LAPTOP, 400.0);
        assert!(x + 696.0 <= LAPTOP.right(), "x={x} overflows the screen");
        assert!(x >= LAPTOP.x);
    }

    /// A tray on the bottom edge (the Windows default) opens upward.
    #[test]
    fn panel_flips_above_a_bottom_edge_tray() {
        let taskbar = Area {
            x: 0.0,
            y: 0.0,
            w: 1920.0,
            h: 1040.0,
        };
        let icon = TrayAnchor {
            x: 1800.0,
            y: 1040.0,
            width: 32.0,
            height: 40.0,
        };
        let (_, y) = origin(Some(icon), taskbar, 400.0);
        assert_eq!(
            y + 400.0,
            icon.y,
            "panel should end where the taskbar starts"
        );
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
    fn each_status_gets_its_own_color_in_both_appearances() {
        for dark in [false, true] {
            let colors: std::collections::HashSet<_> = Status::DEFAULT_PRIORITY
                .iter()
                .map(|s| status_rgb(*s, dark))
                .collect();
            assert_eq!(colors.len(), Status::DEFAULT_PRIORITY.len(), "dark={dark}");
        }
    }
}
