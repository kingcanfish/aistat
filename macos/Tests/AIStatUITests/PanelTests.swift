import AIStatCore
import AppKit
import Foundation
import Testing

@testable import AIStatUI

private func site(_ id: String, _ overall: Status) -> SiteStatus {
    SiteStatus(
        id: id, name: id.capitalized, url: "https://status.\(id).com",
        adapter: "statuspage", overall: overall)
}

@Suite("Panel headline")
struct PanelHeadlineTests {
    @Test func namesTheServiceInTrouble() {
        let statuses = [site("claude", .partialOutage), site("openai", .operational)]
        #expect(
            PanelHeadline.text(worst: .partialOutage, statuses: statuses)
                == "Partial outage at Claude")
    }

    /// The count covers everything else that isn't fine, not everything else
    /// at the worst level.
    @Test func countsTheOthersThatAreNotFine() {
        let statuses = [
            site("claude", .fullOutage), site("openai", .degraded),
            site("deepseek", .operational), site("gemini", .unknown),
        ]
        #expect(
            PanelHeadline.text(worst: .fullOutage, statuses: statuses)
                == "Full outage at Claude +2")
    }

    @Test func healthyAndEmptyStatesReadAsSentences() {
        #expect(
            PanelHeadline.text(worst: .operational, statuses: [site("a", .operational)])
                == "All systems operational")
        #expect(PanelHeadline.text(worst: .unknown, statuses: []) == "Nothing monitored")
    }

    /// Nothing came back from anywhere: there is no service to name, and
    /// claiming one would be picking a scapegoat at random.
    @Test func everythingUnreachableNamesNoService() {
        let statuses = [site("claude", .unknown), site("openai", .unknown)]
        #expect(PanelHeadline.text(worst: .unknown, statuses: statuses) == "Status unavailable")
    }
}

@Suite("Menu bar icon")
struct MenuBarGlyphTests {
    /// Severity has to map onto weight, or the escalation is decoration.
    @Test func escalatingMapsSeverityOntoWeight() {
        let expected: [(Status, MenuBarGlyph.Weight)] = [
            (.operational, .calm), (.unknown, .calm),
            (.degraded, .tinted), (.maintenance, .tinted),
            (.partialOutage, .filled), (.fullOutage, .filled),
        ]
        for (status, want) in expected {
            #expect(MenuBarGlyph.weight(for: .escalating, status: status) == want, "\(status)")
        }
    }

    /// The other two styles are deliberately flat — one rule, every state.
    @Test func theOtherStylesArePinned() {
        for status in Status.defaultPriority {
            #expect(MenuBarGlyph.weight(for: .lamp, status: status) == .calm)
            #expect(MenuBarGlyph.weight(for: .tinted, status: status) == .tinted)
        }
    }
}

@Suite("Editing the service list")
@MainActor
struct ServiceEditingTests {
    func model() -> AppModel {
        let model = AppModel(
            configURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("aistat-test-\(UUID().uuidString).json"))
        model.seed(config: Config(sites: []), statuses: [])
        return model
    }

    @Test func addingDerivesAReadableID() {
        let model = model()
        model.upsertSite(
            existingID: nil, name: "Hugging Face", url: "https://status.huggingface.co",
            adapter: .statuspage)
        #expect(model.config.sites.map(\.id) == ["hugging-face"])
    }

    /// Two services whose names slug the same must not collide: the id is what
    /// the snapshot diff matches on, so a collision would make one service's
    /// incidents look like the other's.
    @Test func collidingNamesGetDistinctIDs() {
        let model = model()
        model.upsertSite(existingID: nil, name: "Claude", url: "https://a.com", adapter: .statuspage)
        model.upsertSite(existingID: nil, name: "claude!", url: "https://b.com", adapter: .flashduty)
        #expect(model.config.sites.map(\.id) == ["claude", "claude-2"])
    }

    /// Renaming keeps the id, so a rename doesn't read as "every incident this
    /// service has is new".
    @Test func renamingKeepsTheID() {
        let model = model()
        model.upsertSite(existingID: nil, name: "Claude", url: "https://a.com", adapter: .statuspage)
        model.upsertSite(
            existingID: "claude", name: "Anthropic", url: "https://a.com", adapter: .statuspage)
        #expect(model.config.sites.count == 1)
        #expect(model.config.sites[0].id == "claude")
        #expect(model.config.sites[0].name == "Anthropic")
    }

    @Test func removingDropsTheService() {
        let model = model()
        model.upsertSite(existingID: nil, name: "Claude", url: "https://a.com", adapter: .statuspage)
        model.removeSite("claude")
        #expect(model.config.sites.isEmpty)
    }
}

/// The main menu is never drawn — an accessory app does not own the menu bar —
/// so nothing about it is visible until a shortcut silently stops working.
@Suite("Main menu")
@MainActor
struct MainMenuTests {
    /// `NSApplication.sendEvent` offers each key-down to the main menu before
    /// the key window sees it, and that is the only thing that turns ⌘V into a
    /// `paste:` down the responder chain. Losing one of these items means that
    /// key does nothing in every text field the app has.
    @Test func carriesTheClipboardKeyEquivalents() throws {
        let edit = try #require(
            MainMenu.make().items.compactMap(\.submenu).first { $0.title == "Edit" })

        let expected: [(String, String)] = [
            ("Cut", "x"), ("Copy", "c"), ("Paste", "v"), ("Select All", "a"),
            ("Undo", "z"), ("Redo", "Z"),
        ]
        for (title, key) in expected {
            let item = try #require(edit.items.first { $0.title == title }, "no \(title) item")
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask.contains(.command), "\(title) is not ⌘-\(key)")
            // Left unimplemented on purpose: these resolve against whatever
            // has focus, so an item with no action would be permanently
            // disabled instead.
            #expect(item.action != nil, "\(title) has no action")
        }
    }

    @Test func quitIsReachableFromTheSettingsWindow() throws {
        let app = try #require(MainMenu.make().items.first?.submenu)
        let quit = try #require(app.items.first { $0.title.hasPrefix("Quit") })
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }
}
