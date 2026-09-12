import AppKit

/// The invisible main menu.
///
/// An `LSUIElement` app never shows a menu bar of its own, which makes it easy
/// to conclude it does not need a menu — and then Cut, Copy, Paste and Select
/// All stop working in every text field the app has, with no error and no clue
/// why. The keys are not handled by the text field: `NSApplication.sendEvent`
/// offers each key-down to `mainMenu.performKeyEquivalent(_:)` first, and that
/// is where ⌘V turns into a `paste:` message down the responder chain. With
/// `mainMenu` nil there is nothing to perform the equivalent, so the keystroke
/// reaches the field as an ordinary character and is discarded.
///
/// So the menu exists purely to be asked. Nothing here is ever drawn: an
/// accessory app does not own the menu bar even while one of its windows is
/// key. The actions are left unimplemented on purpose — `cut:`, `copy:` and the
/// rest are resolved against the first responder at the moment they fire, which
/// is the field editor of whichever text field has focus.
@MainActor
enum MainMenu {
    static func install() {
        NSApp.mainMenu = make()
    }

    /// Split from ``install()`` so the key equivalents can be asserted without
    /// an `NSApplication` — this whole menu is invisible, so a missing item is
    /// not something anyone notices until a text field stops pasting.
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        return mainMenu
    }

    /// Carries ⌘Q. The panel offers Quit too, but only while it is open; this
    /// covers the settings window, which is the one place the app has a real
    /// window and the shortcut is expected to work.
    private static func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit AIStat", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        // Undo and redo are sent by selector name: `NSUndoManager`'s actions
        // are not exposed as Swift selectors to link against, and the responder
        // chain resolves them by name anyway.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }
}
