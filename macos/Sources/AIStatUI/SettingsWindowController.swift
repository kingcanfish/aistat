import AIStatCore
import AppKit
import SwiftUI

/// The settings window.
///
/// Owned outright rather than declared as a SwiftUI `Settings` scene. Two
/// things went wrong with the scene, and both come from the same place — this
/// app is an accessory (`LSUIElement`), so it has no main menu:
///
/// * `SettingsLink` reads its action out of the *scene* environment, and the
///   panel is hosted in an `NSPopover` built by hand, which has no scene above
///   it. The link rendered and did nothing.
/// * `NSApp.sendAction(Selector(("showSettingsWindow:")))` is answered by the
///   app menu's Settings item. With no main menu there is no responder, so the
///   action goes nowhere and the button is dead.
///
/// An `NSWindow` we open ourselves has neither problem, and the thing that
/// actually mattered — that settings live in a *window*, which cannot be
/// dismissed by clicking elsewhere, so no "pinned" flag is needed to protect a
/// half-typed form — is unchanged.
@MainActor
final class SettingsWindowController {
    /// Where the window was last left. Remembering it is the macOS habit: a
    /// settings window you moved should be where you put it next time.
    private static let frameAutosaveName = "AIStatSettingsWindow"

    private let model: AppModel
    private let selection = SettingsSelection()
    /// Held because `NSToolbar` does not retain its delegate.
    private var toolbar: SettingsToolbar?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// For `aistat-preview`, which needs each pane without a click.
    func selectPreviewTab(_ tab: SettingsSelection.Tab) {
        selection.tab = tab
    }

    func show() {
        if window == nil { window = makeWindow() }
        // An accessory app is never frontmost on its own, and a settings window
        // that opens behind the app you were using cannot take keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Internal rather than private so `aistat-preview` can capture the real
    /// window — title bar and toolbar included — instead of only its content.
    func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsScene(model: model, selection: selection))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AIStat Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]

        // The pane switcher lives in the title bar, the way every macOS
        // settings window's does. See SettingsToolbar for what the obvious
        // alternative looked like.
        let toolbar = SettingsToolbar(selection: selection)
        toolbar.install(on: window)
        self.toolbar = toolbar
        // Closing must not destroy it: the model is bound into the view, and
        // rebuilding it on every open would drop in-flight edits.
        window.isReleasedWhenClosed = false

        // Size before placing, and this is the whole fix for where the window
        // used to land. `NSWindow(contentViewController:)` hands back a window
        // of roughly nothing — measured at 1×32 — because SwiftUI has not laid
        // out yet. Centring *that* put a one-point window in the middle of the
        // screen, and the real content then grew right and down out of its
        // top-left corner, which is how a centred window ended up in the
        // top-right quadrant.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)

        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        // Re-applied after the restore: the window is not resizable, so its
        // size is whatever the current layout needs — an older saved frame must
        // not be allowed to impose a stale one. `setContentSize` keeps the
        // top-left corner, so the remembered position survives.
        window.setContentSize(hosting.view.fittingSize)
        return window
    }
}
