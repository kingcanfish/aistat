import AIStatCore
import SwiftUI

/// Fixed readings for the offscreen preview renderer.
///
/// These are shapes that are awkward to reach against live status pages — a
/// full outage, an unreachable host, a page with components but no incident —
/// which are exactly the states a layout change is most likely to break.
public enum PreviewData {
    public static let sites: [SiteConfig] = [
        SiteConfig(id: "claude", name: "Claude", url: "https://status.claude.com", adapter: .statuspage),
        SiteConfig(id: "openai", name: "OpenAI", url: "https://status.openai.com", adapter: .statuspage),
        SiteConfig(id: "deepseek", name: "DeepSeek", url: "https://status.deepseek.com", adapter: .flashduty),
        SiteConfig(id: "gemini", name: "Gemini", url: "https://status.cloud.google.com", adapter: .statuspage),
    ]

    static let now = Date()

    public static let trouble: [SiteStatus] = [
        SiteStatus(
            id: "claude", name: "Claude", url: "https://status.claude.com", adapter: "statuspage",
            overall: .partialOutage,
            components: [
                Component(name: "claude.ai", status: .operational),
                Component(name: "Claude Console (platform.claude.com)", status: .operational),
                Component(name: "Claude Cowork", status: .partialOutage),
                Component(name: "Claude Code", status: .degraded),
            ],
            incidents: [
                Incident(
                    id: "inc-1",
                    title: "Degraded functionality for Claude Cowork on Windows",
                    impact: .partialOutage, lifecycle: "identified",
                    latestUpdate:
                        "A Windows update has left Claude Cowork unable to run local commands. Chat and file editing still work. Microsoft has a fix in progress.",
                    updatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
                )
            ],
            fetchedAt: now.addingTimeInterval(-240)
        ),
        SiteStatus(
            id: "openai", name: "OpenAI", url: "https://status.openai.com", adapter: "statuspage",
            overall: .degraded,
            components: [
                Component(name: "API", status: .degraded),
                Component(name: "ChatGPT", status: .operational),
                Component(name: "Sora", status: .operational),
            ],
            fetchedAt: now.addingTimeInterval(-240)
        ),
        SiteStatus(
            id: "deepseek", name: "DeepSeek", url: "https://status.deepseek.com", adapter: "flashduty",
            overall: .operational, fetchedAt: now.addingTimeInterval(-240)
        ),
        SiteStatus(
            id: "gemini", name: "Gemini", url: "https://status.cloud.google.com", adapter: "statuspage",
            overall: .unknown, fetchedAt: now.addingTimeInterval(-240),
            error: "A server with the specified hostname could not be found."
        ),
    ]

    public static let healthy: [SiteStatus] = trouble.map {
        var copy = $0
        copy.overall = .operational
        copy.incidents = []
        copy.error = nil
        copy.components = copy.components.map { Component(name: $0.name, status: .operational) }
        return copy
    }

    @MainActor
    static func selection(_ tab: SettingsSelection.Tab) -> SettingsSelection {
        let selection = SettingsSelection()
        selection.tab = tab
        return selection
    }

    @MainActor
    static var failedDraft: ServiceDraft {
        let draft = ServiceDraft.new()
        draft.name = "Mistral"
        draft.url = "https://mistral.ai"
        draft.probe = .failed(
            "No supported status API here. AIStat reads Atlassian Statuspage, incident.io and FlashDuty pages."
        )
        return draft
    }

    @MainActor
    static func model(
        sites: [SiteConfig] = sites, statuses: [SiteStatus]
    ) -> AppModel {
        let model = AppModel(
            configURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("aistat-preview-config.json"))
        var config = Config()
        config.sites = sites
        model.seed(config: config, statuses: statuses)
        return model
    }
}

@MainActor
public enum StatusPanelPreview {
    /// The state the panel exists for: something is wrong, one service is
    /// unreachable, and the worst of them is expanded.
    public static var trouble: some View {
        StatusPanel(model: PreviewData.model(statuses: PreviewData.trouble), initiallyExpanded: ["claude"])
    }

    public static var healthy: some View {
        StatusPanel(model: PreviewData.model(statuses: PreviewData.healthy))
    }

    public static var empty: some View {
        StatusPanel(model: PreviewData.model(sites: [], statuses: []))
    }
}

@MainActor
public enum SettingsPreview {
    public static var general: some View {
        SettingsScene(
            model: PreviewData.model(statuses: PreviewData.trouble),
            selection: PreviewData.selection(.general))
    }

    public static var services: some View {
        SettingsScene(
            model: PreviewData.model(statuses: PreviewData.trouble),
            selection: PreviewData.selection(.services))
    }

    /// The whole window, chrome included. The pane switcher is an `NSToolbar`
    /// in the title bar, so rendering the content alone would miss it — and
    /// missing chrome is exactly how the `TabView` it replaced got shipped.
    public static func window(tab: SettingsSelection.Tab) -> NSWindow {
        let controller = SettingsWindowController(model: PreviewData.model(statuses: PreviewData.trouble))
        controller.selectPreviewTab(tab)
        return controller.makeWindow()
    }

    /// The add/edit sheet, mid-probe failure — the state the old build could
    /// only reach as a modal alert after pressing Save.
    public static var editor: some View {
        ServiceEditor(
            draft: PreviewData.failedDraft,
            model: PreviewData.model(statuses: PreviewData.trouble))
    }
}

/// Every icon style in every state, as the menu bar would draw it.
@MainActor
public enum MenuBarIconPreview {
    public static var grid: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(IconStyle.allCases, id: \.self) { style in
                HStack(spacing: 16) {
                    Text(style.menuTitle)
                        .font(.caption)
                        .frame(width: 120, alignment: .leading)
                    ForEach(Status.defaultPriority.reversed(), id: \.self) { status in
                        MenuBarGlyph(status: status, style: style)
                    }
                }
            }
            Divider()
            // Magnified, because an 18 pt mark hides the two things most
            // likely to be wrong: whether the lamp is punched out of the
            // outline, and whether the filled weight keeps its eyes open.
            HStack(spacing: 24) {
                ForEach(
                    [(Status.operational, IconStyle.escalating),
                     (.degraded, .escalating),
                     (.fullOutage, .escalating)], id: \.0
                ) { status, style in
                    MenuBarGlyph(status: status, style: style)
                        .scaleEffect(5, anchor: .center)
                        .frame(width: 90, height: 90)
                }
            }
        }
        .padding(20)
    }
}
