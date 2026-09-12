import AIStatCore
import AppKit

public enum AppInfo {
    public static let repositoryURL = URL(string: "https://github.com/kingcanfish/aistat")!
}

/// Entry point.
///
/// Plain `NSApplication` rather than a SwiftUI `App`. There is no scene left to
/// declare: the menu bar item is an `NSStatusItem` (see ``MenuBarController``
/// for the measurement that settled that), the panel is an `NSPopover`, and the
/// settings window is opened directly (see ``SettingsWindowController``).
/// SwiftUI draws the contents of all three.
public enum AIStatRunner {
    @MainActor
    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no app switcher entry. The bundled
        // Info.plist carries LSUIElement for the same reason; this covers the
        // un-bundled `swift run` case.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Opens the settings window from anywhere in the UI.
@MainActor
func openSettingsWindow() {
    AppDelegate.shared?.showSettings()
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var menuBar: MenuBarController?
    private var settings: SettingsWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Before any window exists: without this, ⌘C and ⌘V do nothing in the
        // settings fields and in the selectable incident text.
        MainMenu.install()
        Notifier.requestAuthorization()

        let model = AppModel.shared
        let menuBar = MenuBarController(model: model)
        self.menuBar = menuBar
        self.settings = SettingsWindowController(model: model)

        // The status item is the only thing outside SwiftUI that has to react
        // to a refresh or a settings change, so the model reaches it through
        // one callback rather than knowing about AppKit.
        model.onDisplayStateChanged = { [weak menuBar] in menuBar?.redraw() }

        Task {
            await model.refresh()
            model.startScheduler()
        }
    }

    /// `open -a AIStat` on an already-running menu bar app otherwise does
    /// nothing at all, which reads as "it didn't start" — there is no window
    /// for AppKit to bring forward. Showing the panel is the visible answer to
    /// what the user was asking for.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        menuBar?.showPanel()
        return false
    }

    func showSettings() {
        // The panel is transient and will dismiss itself when the window takes
        // focus; closing it first keeps the two from overlapping on screen.
        menuBar?.closePanel()
        settings?.show()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopScheduler()
    }
}
