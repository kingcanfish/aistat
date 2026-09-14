import AIStatCore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AIStatUI

private func site(_ id: String, _ overall: Status) -> SiteStatus {
    SiteStatus(
        id: id, name: id.capitalized, url: "https://status.\(id).com",
        adapter: "statuspage", overall: overall)
}

/// Every suite here is `@MainActor`, and deliberately so rather than by need.
/// SwiftUI infers main-actor isolation for a `View` from its `body`, and it
/// does so differently between toolchains — `MenuBarGlyph.weight(for:status:)`
/// is isolated under the Xcode the release runner has and was not under the
/// newer one this was written on, which failed a release build and nothing
/// before it. Annotating the whole layer, which is main-actor in nature anyway,
/// takes the inference out of the question.
@Suite("Panel headline")
@MainActor
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
@MainActor
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

/// The services list is capped, so a long one scrolls — and a row that grows
/// the list past the cap must not re-lay-out the rows that are already there.
/// Asserted against the AppKit view SwiftUI builds, because nothing else in
/// the suite can see what a scroll view does with its own width.
@Suite("Panel services list")
@MainActor
struct PanelListScrollTests {
    /// The real panel, hosted off-screen, with more rows than fit.
    private func hostedPanel() -> NSView {
        let statuses = (0..<8).map { site("service-\($0)", .operational) }
        let model = AppModel(
            configURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("aistat-test-\(UUID().uuidString).json"))
        model.seed(
            config: Config(
                sites: statuses.map {
                    SiteConfig(id: $0.id, name: $0.name, url: $0.url, adapter: .statuspage)
                }),
            statuses: statuses)

        let hosting = NSHostingView(
            rootView: StatusPanel(model: model, initiallyExpanded: Set(statuses.map(\.id))))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        // A window, because the scroll view is built during a layout pass —
        // and an app object behind it, since a test process starts with
        // neither.
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        return hosting
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// A scroll view on a Mac set to "Show scroll bars: Always" charges its
    /// scroller to the clip view's width — 17 of the panel's 320 points,
    /// measured — rather than floating it over the content. So expanding one
    /// row narrowed every row and slid the right-hand status column left. The
    /// panel asks for no indicator, which costs it nothing and leaves wheel and
    /// trackpad scrolling alone.
    @Test func theListNeverPaysForAScroller() throws {
        let scroll = try #require(firstScrollView(in: hostedPanel()))
        #expect(scroll.hasVerticalScroller == false)
        #expect(scroll.contentView.frame.width == scroll.frame.width)
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

/// Counts how often the model announced a finished refresh. A class because the
/// callback escapes.
@MainActor
private final class RefreshCounter {
    var count = 0
}

@Suite("Refreshing")
@MainActor
struct RefreshTests {
    /// No sites, so nothing here touches the network: `fetchAll` and the icon
    /// resolver both return early on an empty list.
    func model() -> AppModel {
        let model = AppModel(
            configURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("aistat-test-\(UUID().uuidString).json"))
        model.seed(config: Config(sites: []), statuses: [])
        return model
    }

    /// The scheduler can come due while the user is mid-refresh — the button is
    /// disabled then, so the UI cannot prevent it. Overlapping fetches did the
    /// work twice and let whichever finished first re-enable the button while
    /// the other was still running.
    @Test func concurrentRefreshesCoalesce() async {
        let model = model()
        let counter = RefreshCounter()
        model.onDisplayStateChanged = { counter.count += 1 }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await model.refresh() } }
        }

        #expect(counter.count >= 1)
        #expect(counter.count < 5, "five at once should not have fetched five times")
    }

    /// The other half, and the one that fails silently: if the in-flight task is
    /// not cleared when it finishes, every later refresh joins a completed one
    /// and the app quietly stops updating.
    @Test func refreshingAgainAfterwardsStillWorks() async {
        let model = model()
        let counter = RefreshCounter()
        model.onDisplayStateChanged = { counter.count += 1 }

        await model.refresh()
        await model.refresh()
        await model.refresh()

        #expect(counter.count == 3)
        #expect(model.isRefreshing == false)
    }
}
