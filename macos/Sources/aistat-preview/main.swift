import AIStatCore
import AIStatUI
import AppKit
import SwiftUI

/// Renders the panel and the settings window offscreen, in both appearances.
///
/// ```sh
/// swift run aistat-preview [output-directory]
/// ```
///
/// Deliberately *not* `ImageRenderer`: half of what a macOS app is made of —
/// `Form`, `List`, `TabView`, `Menu`, `Link` — is AppKit underneath, and
/// `ImageRenderer` draws a placeholder where it meets one, so the settings
/// window came back as a single "unavailable" glyph. Hosting the view in an
/// off-screen window and asking AppKit to cache its display renders exactly
/// what the app will show, control chrome included.
@MainActor
func render() {
    let outputDirectory =
        CommandLine.arguments.count > 1
        ? URL(fileURLWithPath: CommandLine.arguments[1])
        : URL(fileURLWithPath: "preview")
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for (name, tab) in [("settings-window-general", SettingsSelection.Tab.general),
                        ("settings-window-services", .services)] {
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            guard let png = snapshotWindow(SettingsPreview.window(tab: tab), appearance: appearance)
            else {
                print("could not render \(name)")
                continue
            }
            let url = outputDirectory.appendingPathComponent(
                "\(name)-\(scheme == .dark ? "dark" : "light").png")
            try? png.write(to: url)
            print("wrote \(url.lastPathComponent)")
        }
    }

    for (name, view) in previews() {
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            guard let png = snapshot(view, appearance: appearance, scheme: scheme) else {
                print("could not render \(name)")
                continue
            }
            let suffix = scheme == .dark ? "dark" : "light"
            let url = outputDirectory.appendingPathComponent("\(name)-\(suffix).png")
            try? png.write(to: url)
            print("wrote \(url.lastPathComponent)")
        }
    }
}

/// Hosts `view` in a window parked off every screen, lays it out, and captures
/// what AppKit would draw.
@MainActor
func snapshot(_ view: AnyView, appearance: NSAppearance, scheme: ColorScheme) -> Data? {
    let hosting = NSHostingView(
        rootView:
            view
            .environment(\.colorScheme, scheme)
            // Window materials don't exist off-screen, so each sheet is drawn
            // over the window background it will actually sit on.
            .background(Color(nsColor: .windowBackgroundColor))
    )
    hosting.appearance = appearance

    let size = hosting.fittingSize
    guard size.width > 1, size.height > 1 else { return nil }
    hosting.frame = CGRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = hosting
    window.orderBack(nil)
    // Two passes: `Form` and `List` size their rows on the first layout and
    // only settle on the second.
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    window.orderOut(nil)
    return rep.representation(using: .png, properties: [:])
}

/// Captures a whole window, title bar and toolbar included, by drawing the
/// frame view rather than the content view.
@MainActor
func snapshotWindow(_ window: NSWindow, appearance: NSAppearance) -> Data? {
    window.appearance = appearance
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.orderBack(nil)
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    guard let frameView = window.contentView?.superview,
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
    else { return nil }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    window.orderOut(nil)
    return rep.representation(using: .png, properties: [:])
}

@MainActor
func previews() -> [(String, AnyView)] {
    [
        ("panel-trouble", AnyView(StatusPanelPreview.trouble)),
        ("panel-healthy", AnyView(StatusPanelPreview.healthy)),
        ("panel-empty", AnyView(StatusPanelPreview.empty)),
        ("settings-editor", AnyView(SettingsPreview.editor)),
        ("menubar-icons", AnyView(MenuBarIconPreview.grid)),
    ]
}

// A menu bar app never activates, but the preview tool needs AppKit awake
// enough to lay out real controls.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
render()
