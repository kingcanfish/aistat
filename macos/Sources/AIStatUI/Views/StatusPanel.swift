import AIStatCore
import AppKit
import SwiftUI

/// The menu bar panel.
///
/// Laid out as three fixed bands — a headline, the services, and the actions
/// that used to live in a right-click menu no one could discover. The web
/// panel's chrome (custom scroll containers, a hand-drawn chevron, a bespoke
/// alert sheet, an empty state built from divs) is all SwiftUI stock here.
struct StatusPanel: View {
    @Bindable var model: AppModel
    @State private var expanded: Set<String>

    init(model: AppModel, initiallyExpanded: Set<String> = []) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    /// The panel stays as tall as its content up to this, then scrolls. Chosen
    /// so a four-service list with one incident open still fits without one.
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320)
        .onChange(of: model.config.sites.map(\.id)) { _, live in
            // A service removed in settings shouldn't leave its row expanded
            // when it comes back.
            expanded.formIntersection(live)
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 9) {
            StatusBadge(status: model.overall, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(PanelHeadline.text(worst: model.overall, statuses: model.statuses))
                    .font(.headline)
                    .lineLimit(1)
                if let updated = model.statuses.compactMap(\.fetchedAt).max() {
                    // Relative and self-updating, which a formatted clock time
                    // never was: "Updated 4 minutes ago" is the thing you
                    // actually want to know about a cached reading.
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            if model.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.accessoryBar)
        .disabled(model.isRefreshing)
        .help("Refresh now")
        .keyboardShortcut("r")
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        if model.config.sites.isEmpty {
            // Stock, and it carries its own call to action — the web build
            // wrote this out of divs and a bespoke button.
            ContentUnavailableView {
                Label("No services", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text("Add a status page and AIStat will keep an eye on it.")
            } actions: {
                Button("Add a service…") { openSettingsWindow() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 8)
        } else if model.statuses.isEmpty {
            ContentUnavailableView(
                "Checking…", systemImage: "ellipsis.circle",
                description: Text("Reading \(model.config.sites.count) status pages."))
            .padding(.vertical, 8)
        } else {
            // Hugs its content and starts scrolling past the cap: a
            // `ScrollView`'s ideal height is its content's, so the `maxHeight`
            // is the only clamp needed. The web build spelled the same idea out
            // as a `ResizeObserver` measuring the list, an IPC call carrying
            // the number to Rust, and a clamp there that resized the window and
            // re-anchored it.
            //
            // Deliberately not `ViewThatFits`: it needs a bounded proposal to
            // choose between its children, and the popover proposes the ideal
            // size, so it would always pick the unscrolling variant and let the
            // panel grow past the bottom of the screen.
            ScrollView {
                serviceList
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxListHeight)
        }
    }

    /// Not lazy: a menu bar panel holds a handful of rows, and a `LazyVStack`
    /// only pays off past a screenful.
    private var serviceList: some View {
        VStack(spacing: 2) {
            ForEach(model.statuses) { site in
                SiteRow(
                    site: site,
                    isExpanded: expanded.contains(site.id),
                    toggle: { toggle(site.id) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Unanimated on purpose. The popover resizes itself from the content's
    /// ideal size, so animating the content makes the window chase it frame by
    /// frame — which reads as the panel juddering rather than opening.
    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - footer

    /// What used to be the tray icon's right-click menu. A menu you have to
    /// know to right-click for is a menu most people never find; these are two
    /// buttons in the panel they already have open.
    ///
    /// Two *buttons*, specifically, and not a `Menu` behind an ellipsis, which
    /// is what this was first. Opening an `NSMenu` from inside a transient
    /// `NSPopover` leaves the popover's window no longer key once the menu's
    /// tracking loop ends — and "no longer key" is the very thing `.transient`
    /// waits for in order to dismiss, so the panel was left on screen with
    /// nothing able to close it. The menu held two items, one of which (the
    /// project link) the settings window already has, so there was nothing to
    /// preserve.
    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                openSettingsWindow()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut(",")

            Spacer(minLength: 0)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("q")
            .help("Quit AIStat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
