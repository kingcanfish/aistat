import AIStatCore
import SwiftUI

/// Which pane the settings window is showing.
///
/// Shared between the window's toolbar, which is AppKit, and the content, which
/// is SwiftUI — the two halves of one control.
@MainActor
@Observable
public final class SettingsSelection {
    public enum Tab: String, CaseIterable {
        case general, services

        public var title: String {
            switch self {
            case .general: "General"
            case .services: "Services"
            }
        }

        public var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .services: "globe"
            }
        }
    }

    var tab: Tab = .general

    public init() {}
}

/// The settings window's content.
///
/// Changes apply as they are made, which is the macOS convention and the reason
/// the Save/Cancel pair is gone. Those buttons existed because settings lived
/// inside a panel that could vanish mid-edit; a window can't, so the "pinned"
/// flag, the dirty tracking and the deferred write it all fed are gone with it.
///
/// Deliberately no `TabView`. A settings window puts its panes in the title bar
/// — that is what `NSWindow.toolbarStyle = .preference` is for, and what
/// ``SettingsWindowController`` builds. A `TabView` here instead drew its own
/// tab strip *below* the title bar, with its own bottom border: a second
/// horizontal rule under the window's own, and tabs in a band that no macOS
/// settings window has.
struct SettingsScene: View {
    @Bindable var model: AppModel
    @Bindable var selection: SettingsSelection

    var body: some View {
        Group {
            switch selection.tab {
            case .general: GeneralSettings(model: model)
            case .services: ServiceSettings(model: model)
            }
        }
        // Fixed rather than sized per pane: the two want different heights, and
        // a window that resizes as you switch between them moves the control
        // you were about to click.
        .frame(width: 460, height: 420)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel

    /// Presets rather than a free seconds field. The old number box could be
    /// set to anything and was clamped to 30s behind the user's back; these are
    /// the intervals anyone actually wants, and the floor stops being a rule
    /// you can only discover by breaking it.
    private static let presets: [(String, UInt64)] = [
        ("Every 30 seconds", 30), ("Every minute", 60), ("Every 5 minutes", 300),
        ("Every 15 minutes", 900), ("Every 30 minutes", 1800), ("Every hour", 3600),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Check services", selection: $model.config.refreshIntervalSeconds) {
                    ForEach(Self.presets, id: \.1) { Text($0.0).tag($0.1) }
                    // A config file edited by hand can hold anything; keep it
                    // selectable rather than silently snapping to a preset.
                    if !Self.presets.contains(where: { $0.1 == model.config.refreshIntervalSeconds }) {
                        Divider()
                        Text("Every \(model.config.refreshIntervalSeconds) seconds")
                            .tag(model.config.refreshIntervalSeconds)
                    }
                }
                Toggle("Notify when a service changes state", isOn: $model.config.notificationsEnabled)
                Toggle("Start at login", isOn: $model.config.launchAtLogin)
            }

            Section {
                Picker("Menu bar icon", selection: $model.config.iconStyle) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Text(style.menuTitle).tag(style)
                    }
                }
                // Worth more than the three words in the picker: this is
                // exactly what the menu bar will show in each state, drawn by
                // the same view that draws it there.
                LabeledContent("Preview") {
                    HStack(spacing: 10) {
                        ForEach(Status.defaultPriority.reversed(), id: \.self) { status in
                            MenuBarGlyph(status: status, style: model.config.iconStyle)
                                .help(status.label)
                        }
                    }
                }
            } footer: {
                Text(model.config.iconStyle.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Version", value: AIStatCore.version)
                Link("Project on GitHub", destination: AppInfo.repositoryURL)
            }
        }
        .formStyle(.grouped)
    }
}

extension IconStyle {
    /// One sentence on what the choice costs, since all three are defensible
    /// and the difference is a matter of how much of the menu bar's quiet the
    /// icon is allowed to spend.
    var explanation: String {
        switch self {
        case .escalating:
            "Monochrome while healthy, tinted when degraded, filled when something is down. Weight survives peripheral vision in a way hue alone does not."
        case .lamp:
            "Monochrome in every state, with the status carried by the corner lamp alone. The quietest of the three, and the hardest to read at a glance."
        case .tinted:
            "The whole mark carries the status colour in every state, healthy included. One rule to learn, at the cost of colour in the bar all day."
        }
    }
}

// MARK: - services

struct ServiceSettings: View {
    @Bindable var model: AppModel
    @State private var editing: ServiceDraft?

    /// A grouped form, like the General pane next to it, rather than a bare
    /// `List` over a strip of `+ − ✎` buttons. That strip is the pre-Tahoe
    /// idiom — a gradient button bar glued under a table — and against the
    /// grouped General pane it made the window look like two apps. System
    /// Settings now edits a list the way this does: rows in a rounded group,
    /// a details button on each row, and the add action under the group.
    ///
    /// Losing selection loses nothing: the minus and pencil buttons were the
    /// only things that read it, and each row now carries its own edit button,
    /// its own context menu, and a Remove button in the sheet it opens.
    var body: some View {
        Group {
            if model.config.sites.isEmpty {
                ContentUnavailableView {
                    Label("No services", systemImage: "globe")
                } description: {
                    Text("AIStat watches Atlassian Statuspage, incident.io and FlashDuty pages.")
                } actions: {
                    Button("Add a service…") { editing = .new() }
                        .buttonStyle(.glassProminent)
                }
            } else {
                Form {
                    Section {
                        ForEach(model.config.sites) { site in
                            ServiceListRow(
                                site: site,
                                status: model.status(for: site.id),
                                edit: { editing = ServiceDraft(site) }
                            )
                            .contextMenu {
                                Button("Edit…") { editing = ServiceDraft(site) }
                                Button("Remove", role: .destructive) { model.removeSite(site.id) }
                            }
                            // Not `.onMove`: on macOS that is only wired up
                            // inside a `List`, and in a grouped `Form` it
                            // compiles, shows nothing and moves nothing. Each
                            // row is its own drag source and drop target
                            // instead, carrying the service id.
                            .draggable(site.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first else { return false }
                                withAnimation { model.moveSite(id, to: site.id) }
                                return true
                            }
                        }
                    } footer: {
                        HStack {
                            Text("Drag to reorder. The panel lists services in this order.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Add Service…") { editing = .new() }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .sheet(item: $editing) { draft in
            ServiceEditor(draft: draft, model: model)
        }
    }
}

private struct ServiceListRow: View {
    var site: SiteConfig
    var status: SiteStatus?
    var edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let status {
                StatusBadge(status: status.overall, size: 12)
            } else {
                Image(systemName: "circle.dotted").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                Text(site.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(site.adapter.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: .capsule)
            // The row's own details button, which is how System Settings lets
            // you into one item of a list. Double-clicking a row was the old way
            // in, and a form row has no double-click to give.
            Button(action: edit) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Edit \(site.name)")
            .accessibilityLabel("Edit \(site.name)")
        }
        .padding(.vertical, 2)
    }
}

extension AdapterKind {
    var displayName: String {
        switch self {
        case .statuspage: "Statuspage"
        case .flashduty: "FlashDuty"
        }
    }
}

// MARK: - the add/edit sheet

/// An in-flight edit. Kept out of the config until the URL has been proven
/// readable, so the poller never sees a half-typed address.
@MainActor
@Observable
final class ServiceDraft: Identifiable, @unchecked Sendable {
    enum Probe: Equatable {
        case idle
        case checking
        case found(AdapterKind)
        case failed(String)
    }

    let id = UUID()
    /// nil for a new service; the existing id when editing one.
    let existingID: String?
    var name: String
    var url: String
    var probe: Probe

    init(_ site: SiteConfig) {
        existingID = site.id
        name = site.name
        url = site.url
        probe = .found(site.adapter)
    }

    private init() {
        existingID = nil
        name = ""
        url = ""
        probe = .idle
    }

    static func new() -> ServiceDraft { ServiceDraft() }

    var canSave: Bool {
        if case .found = probe { return !name.trimmed.isEmpty && !url.trimmed.isEmpty }
        return false
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Add or edit one service.
///
/// The adapter is detected here, as soon as the URL is committed, and the
/// answer is shown in place. The web build deferred the same probe to the
/// moment you pressed Save and reported failures in a modal alert — which meant
/// finding out that a page was unreadable only after deciding you were done
/// with the form.
struct ServiceEditor: View {
    @Bindable var draft: ServiceDraft
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $draft.name, prompt: Text("Claude"))
            TextField("Status page", text: $draft.url, prompt: Text("status.claude.com"))
                .onSubmit { Task { await check() } }
                .onChange(of: draft.url) { _, _ in draft.probe = .idle }

            if case .failed(let message) = draft.probe {
                // A sentence long enough to explain itself doesn't belong
                // squeezed into a form's right-hand column.
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .font(.callout)
            } else {
                LabeledContent("Service type") { probeLabel }
            }
        }
        .formStyle(.grouped)
        // Placements rather than a hand-built button row under a `Divider`:
        // in a sheet the system lays these out itself, in the current
        // release's style, and keeps Remove apart from the pair you confirm
        // with.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let id = draft.existingID {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) {
                        model.removeSite(id)
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if case .found = draft.probe {
                    Button(draft.existingID == nil ? "Add" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.canSave)
                } else {
                    Button("Check") { Task { await check() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.url.trimmed.isEmpty || draft.probe == .checking)
                }
            }
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private var probeLabel: some View {
        switch draft.probe {
        case .idle:
            Text("Detected from the URL").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .found(let kind):
            Label(kind.displayName, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            // Rendered as a full-width row instead; see the form above.
            EmptyView()
        }
    }

    private func check() async {
        guard case .success(let url) = normalizeURL(draft.url) else {
            draft.probe = .failed("That doesn't look like a web address.")
            return
        }
        draft.url = url
        draft.probe = .checking
        if let kind = await Providers.detectAdapter(client: model.probeClient, url: url) {
            draft.probe = .found(kind)
            if draft.name.trimmed.isEmpty { draft.name = Self.suggestName(from: url) }
        } else {
            draft.probe = .failed(
                "No supported status API here. AIStat reads Atlassian Statuspage, incident.io and FlashDuty pages."
            )
        }
    }

    /// `status.claude.com` → `Claude`, so the common case needs one field.
    private static func suggestName(from url: String) -> String {
        guard let host = URL(string: url)?.host() else { return "" }
        let parts = host.split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? ""
        return name.capitalized
    }

    private func save() {
        guard case .found(let adapter) = draft.probe else { return }
        model.upsertSite(
            existingID: draft.existingID,
            name: draft.name.trimmed,
            url: draft.url.trimmed,
            adapter: adapter
        )
        dismiss()
    }
}
