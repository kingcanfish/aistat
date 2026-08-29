//! Whether the *menu bar* is currently drawing itself dark.
//!
//! This is deliberately not the system appearance, and the difference is the
//! whole reason this module exists. On modern macOS the menu bar is
//! translucent over the desktop picture, and AppKit picks its content
//! appearance from what is actually behind it — so a Mac in Light appearance
//! with a dark wallpaper gets a *dark* menu bar, with every template icon in
//! it drawn white. `AppleInterfaceStyle`, `NSApp.effectiveAppearance` and
//! Tauri's `Window::theme()` all report Light in that state and are therefore
//! the wrong question to ask; asked anyway, they paint a black glyph onto a
//! black bar.
//!
//! The supported answer is the status item's own
//! `button.effectiveAppearance`, which AppKit keeps correct for exactly this
//! reason. Tauri does not expose its status item, so this keeps a zero-length
//! status item of its own — public API, no visible footprint, and the same
//! value the real item sees — and observes that button's appearance with KVO.
//!
//! KVO rather than a poll because nothing else will ever tell us: changing the
//! desktop picture flips the bar with no theme change, no notification and no
//! user action. Observing is also what makes the startup case work for free —
//! the probe's button reports the *app* appearance until AppKit installs it in
//! the bar, and installing it is itself a change KVO delivers.
//!
//! Apple's actual advice is to sidestep all of this with a template image,
//! which the system tints for you. This app cannot: the status colour has to
//! survive, and a template image keeps nothing but the alpha channel.

use std::sync::atomic::{AtomicU8, Ordering};

const UNKNOWN: u8 = 0;
const LIGHT: u8 = 1;
const DARK: u8 = 2;

/// Last sampled value. AppKit may only be asked from the main thread, but the
/// refresh loop draws the icon from a worker, so the answer is cached here.
static MENU_BAR: AtomicU8 = AtomicU8::new(UNKNOWN);

/// What to do when the bar flips. Set once by [`observe`].
static ON_CHANGE: std::sync::OnceLock<Box<dyn Fn() + Send + Sync>> = std::sync::OnceLock::new();

/// The appearance to draw for right now. Falls back to light before the first
/// successful sample, and on platforms where the question does not arise.
pub fn menu_bar_is_dark() -> bool {
    MENU_BAR.load(Ordering::Relaxed) == DARK
}

/// Starts watching the menu bar, calling `on_change` on the main thread every
/// time it flips. Call once, from the main thread; later calls are ignored.
pub fn observe(on_change: impl Fn() + Send + Sync + 'static) {
    let _ = ON_CHANGE.set(Box::new(on_change));
    platform::ensure_observed();
}

/// Callback for KVO to reach, since the observer class cannot hold a Rust
/// closure of its own.
fn appearance_may_have_changed() {
    if resample() {
        if let Some(on_change) = ON_CHANGE.get() {
            on_change();
        }
    }
}

/// Re-reads the menu bar and returns `true` when the answer changed.
///
/// Must be called on the main thread; returns `false` anywhere else rather
/// than pretending to know.
pub fn resample() -> bool {
    let Some(dark) = platform::read() else {
        return false;
    };
    let now = if dark { DARK } else { LIGHT };
    let changed = MENU_BAR.swap(now, Ordering::Relaxed) != now;
    if changed {
        log::info!(
            "menu bar appearance: {}",
            if dark { "dark" } else { "light" }
        );
    }
    changed
}

#[cfg(target_os = "macos")]
mod platform {
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, NSObject, NSObjectProtocol};
    use objc2::{define_class, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{NSAppearanceCustomization, NSStatusBar, NSStatusItem};
    use objc2_foundation::{
        NSDictionary, NSKeyValueChangeKey, NSKeyValueObservingOptions,
        NSObjectNSKeyValueObserverRegistration, NSString,
    };
    use std::cell::RefCell;
    use std::ffi::c_void;

    /// KVO on the *item*, not the button: the button itself is replaced as
    /// AppKit sets the item up, and `button.effectiveAppearance` follows that
    /// swap where a direct observation of the button would be left behind.
    const KEY_PATH: &str = "button.effectiveAppearance";

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[name = "AIStatMenuBarAppearanceObserver"]
        struct Observer;

        impl Observer {
            #[unsafe(method(observeValueForKeyPath:ofObject:change:context:))]
            fn observe_value(
                &self,
                _key_path: Option<&NSString>,
                _object: Option<&AnyObject>,
                _change: Option<&NSDictionary<NSKeyValueChangeKey, AnyObject>>,
                _context: *mut c_void,
            ) {
                super::appearance_may_have_changed();
            }
        }

        unsafe impl NSObjectProtocol for Observer {}
    );

    struct Probe {
        item: Retained<NSStatusItem>,
        /// Held only to keep the observer alive for as long as it is
        /// registered; KVO does not retain its observers.
        _observer: Retained<Observer>,
    }

    thread_local! {
        /// Never torn down: creating and destroying a status item makes the
        /// real items in the bar shuffle, and this one lives as long as the
        /// process anyway.
        static PROBE: RefCell<Option<Probe>> = const { RefCell::new(None) };
    }

    /// Creates the probe and starts observing it. Idempotent.
    ///
    /// The two halves are deliberately separated by the end of the mutable
    /// borrow. `Initial` makes `addObserver:` deliver the first callback
    /// *synchronously*, and that callback reads the probe straight back — so
    /// registering while still inside the borrow panics the main thread with
    /// "RefCell already borrowed", inside an `extern "C"` frame that cannot
    /// unwind. Which is to say: it aborts the app on launch.
    pub fn ensure_observed() {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };

        let fresh = PROBE.with(|probe| {
            let mut probe = probe.borrow_mut();
            if probe.is_some() {
                return None;
            }
            // Zero length: the button still joins the menu bar's view
            // hierarchy — which is what carries the appearance — while taking
            // no space in it.
            let item = NSStatusBar::systemStatusBar().statusItemWithLength(0.0);
            let observer = Observer::alloc(mtm).set_ivars(());
            let observer: Retained<Observer> = unsafe { objc2::msg_send![super(observer), init] };
            *probe = Some(Probe {
                item: item.clone(),
                _observer: observer.clone(),
            });
            Some((item, observer))
        });

        // Borrow released; re-entering from the `Initial` callback is now fine.
        if let Some((item, observer)) = fresh {
            unsafe {
                item.addObserver_forKeyPath_options_context(
                    &observer,
                    &NSString::from_str(KEY_PATH),
                    NSKeyValueObservingOptions::New | NSKeyValueObservingOptions::Initial,
                    std::ptr::null_mut(),
                );
            }
        }
    }

    pub fn read() -> Option<bool> {
        let mtm = MainThreadMarker::new()?;
        ensure_observed();
        // A shared borrow, so the re-entrant read from a KVO callback nests
        // happily inside the one taken by whoever is already reading.
        PROBE.with(|probe| {
            let probe = probe.borrow();
            let button = probe.as_ref()?.item.button(mtm)?;
            // Matching on the name rather than `bestMatch` because the vibrant
            // menu bar variants are named e.g. `NSAppearanceNameVibrantDark`,
            // which no two-way best match resolves the way you would want.
            let name = button.effectiveAppearance().name();
            Some(name.to_string().to_lowercase().contains("dark"))
        })
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    /// Windows and Linux tray areas do not re-tint what you hand them, and
    /// the icon carries its own contrast there.
    pub fn read() -> Option<bool> {
        None
    }

    pub fn ensure_observed() {}
}
