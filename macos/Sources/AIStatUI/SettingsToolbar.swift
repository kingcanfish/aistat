import AppKit

/// The pane switcher, as a real toolbar in the title bar.
///
/// This is what a macOS settings window looks like — System Settings, Xcode and
/// Safari all put their panes here — and it is what SwiftUI's `Settings` scene
/// builds for you. This app opens its own window, so it builds its own.
///
/// The alternative, a `TabView` in the content, is what was here first, and it
/// looked wrong for a reason worth recording: it draws a tab strip *under* the
/// title bar with its own bottom border, so the window ended up with two
/// horizontal rules across it and its tabs in a band no settings window has.
@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private let selection: SettingsSelection
    private let identifiers: [NSToolbarItem.Identifier]

    init(selection: SettingsSelection) {
        self.selection = selection
        identifiers = SettingsSelection.Tab.allCases.map {
            NSToolbarItem.Identifier($0.rawValue)
        }
        super.init()
    }

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "AIStatSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(selection.tab.rawValue)

        // `.preference` is the style that centres the items under the title and
        // leaves no separator between the toolbar and the content.
        window.toolbarStyle = .preference
        window.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    /// Without this the items are buttons rather than a selector: AppKit only
    /// draws the selected-pane highlight for identifiers listed here.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsSelection.Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(select(_:))
        return item
    }

    @objc private func select(_ sender: NSToolbarItem) {
        guard let tab = SettingsSelection.Tab(rawValue: sender.itemIdentifier.rawValue) else {
            return
        }
        selection.tab = tab
    }
}
