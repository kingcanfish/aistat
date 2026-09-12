import AIStatCore
import AppKit
import SwiftUI

/// The menu bar item and the panel that hangs off it.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra`, and the reason is
/// measured, not stylistic: `MenuBarExtra`'s `label:` closure only renders
/// `Text` and `Image`. Given the `Canvas` that draws this app's mark it
/// produced a status item **4 points wide** — inserted, sized to nothing,
/// invisible. The same app with `MenuBarExtra("AIStat", systemImage:)` got 19
/// points. A custom-drawn menu bar icon is not something that initializer can
/// express, so the item is ours.
///
/// Owning it is also what keeps the appearance handling honest. The menu bar is
/// translucent over the desktop picture and AppKit picks its content appearance
/// from what is behind it, so a Light Mac with a dark wallpaper gets a *dark*
/// menu bar — `AppleInterfaceStyle` and `NSApp.effectiveAppearance` both answer
/// the wrong question. The supported answer is the status item button's own
/// `effectiveAppearance`. The Rust build could not reach Tauri's status item
/// and kept a second, zero-length one purely to have a button to ask; here the
/// button is ours, so the probe is gone and the KVO stays.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel

    private var appearanceObservation: NSKeyValueObservation?
    private var isDark = false
    /// Set between an appearance notification arriving and the coalesced read
    /// that answers it. See ``scheduleAppearanceResample()``.
    private var resamplePending = false
    /// When the popover last closed. A click on the status item while the
    /// panel is open closes it *first* and then arrives here, so a click within
    /// this window of a close must not re-open it.
    private var closedAt: Date?
    private static let reopenDebounce: TimeInterval = 0.25

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let hosting = NSHostingController(rootView: StatusPanel(model: model))
        // Without this the popover keeps whatever size it was first shown at:
        // expanding a row grew the content inside a window that did not follow,
        // and collapsing it left the panel with a band of dead space at the
        // bottom. `.preferredContentSize` republishes SwiftUI's ideal size,
        // which is what `NSPopover` watches.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "AIStat"
        }

        appearanceObservation = statusItem.observe(
            \.button?.effectiveAppearance, options: [.initial, .new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleAppearanceResample() }
        }

        redraw()
    }

    /// Redraws the icon and refreshes the tooltip for the state the app is in.
    func redraw() {
        let overall = model.overall
        statusItem.button?.image = Self.icon(
            status: overall, style: model.config.iconStyle, dark: isDark)
        statusItem.button?.toolTip =
            (["AIStat — \(overall.label)"] + model.statuses.map { "\($0.name): \($0.overall.label)" })
            .joined(separator: "\n")
    }

    // MARK: - the icon

    /// Rasterises the SwiftUI glyph for one appearance.
    ///
    /// The drawing itself stays SwiftUI — `Canvas` paths rather than the Rust
    /// build's hand-sampled distance field — and this only turns it into the
    /// `NSImage` a status item takes. `.primary` inside the glyph resolves
    /// against the appearance installed here, which is the menu bar's, not the
    /// system's.
    static func icon(status: Status, style: IconStyle, dark: Bool) -> NSImage? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(
                content:
                    MenuBarGlyph(status: status, style: style)
                    .environment(\.colorScheme, dark ? .dark : .light)
            )
            // Rendered at 2x and handed back at 18 points, so AppKit has a
            // Retina representation to scale from rather than a 18px bitmap.
            renderer.scale = 2
            image = renderer.nsImage
        }
        image?.size = NSSize(width: 18, height: 18)
        // Explicitly not a template: a template keeps nothing but the alpha
        // channel, and the status colour has to survive.
        image?.isTemplate = false
        return image
    }

    /// Reads the bar on the *next* run loop turn rather than inside the KVO
    /// callout, and collapses a burst of notifications into one read.
    ///
    /// Both halves are load-bearing, and the second was found the hard way.
    /// Redrawing assigns `button.image`, and AppKit resolves the button's
    /// appearance to `NSAppearanceNameDarkAqua` for the duration of that draw
    /// before settling back. Read synchronously, that transient looks exactly
    /// like the user switching to a dark menu bar: the observer fired, redrew,
    /// re-entered itself, and the icon flipped ink twice per refresh on a
    /// machine whose appearance had not moved at all.
    private func scheduleAppearanceResample() {
        guard !resamplePending else { return }
        resamplePending = true
        Task { @MainActor in
            self.resamplePending = false
            guard let appearance = self.statusItem.button?.effectiveAppearance else { return }
            // Matching on the name rather than `bestMatch` because the vibrant
            // menu bar variants are named e.g. `NSAppearanceNameVibrantDark`,
            // which no two-way best match resolves the way you would want.
            let dark = appearance.name.rawValue.lowercased().contains("dark")
            guard dark != self.isDark else { return }
            self.isDark = dark
            Log.tray.info("menu bar appearance: \(dark ? "dark" : "light", privacy: .public)")
            self.redraw()
        }
    }

    // MARK: - the panel

    @objc private func togglePanel() {
        if let closedAt, Date().timeIntervalSince(closedAt) < Self.reopenDebounce {
            self.closedAt = nil
            return
        }
        closedAt = nil

        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // Without this the panel opens behind the front app and its text
            // fields never take key focus.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPanel() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
    }

    deinit { appearanceObservation?.invalidate() }
}
