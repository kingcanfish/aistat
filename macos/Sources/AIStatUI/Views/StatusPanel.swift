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
    @Environment(\.colorScheme) private var colorScheme

    init(model: AppModel, initiallyExpanded: Set<String> = []) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    /// The panel stays as tall as its content up to this, then scrolls. Chosen
    /// so a four-service list with one incident open still fits without one:
    /// the list's old 420-point cap plus the header and footer, which now sit
    /// over the scroll view instead of beside it.
    private static let maxPanelHeight: CGFloat = 520

    /// How much black is laid over the popover's own material in the light
    /// appearance. Left alone it comes out a pale, washed grey, on which the
    /// status hues — system yellow above all — barely read as text: the same
    /// yellow is plain on an incident card's darker ground. Brightening the
    /// panel made that worse, and darkening the hues turned them muddy, so the
    /// ground moves instead, a little. Dark appearance is left as drawn.
    private static let lightShade: Double = 0.08

    /// Clickable size for the panel's icon-only buttons. Comfortably larger
    /// than the glyph inside it, which is the point.
    private static let hitTarget: CGFloat = 24

    var body: some View {
        // Header and footer are bars over the content rather than bands either
        // side of two `Divider`s. That is the Liquid Glass arrangement: the list
        // scrolls under them and the edge effect fades it out, so there is no
        // hard rule across the panel, and a list short enough not to scroll
        // looks the same as it did.
        content
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) { footer }
            .frame(width: 320)
            .frame(maxHeight: Self.maxPanelHeight)
            // Ignores the safe area so it also covers the arrow, which the
            // popover lets content reach (`hasFullSizeContent`); stopping at
            // the content edge left the arrow a different shade from the panel.
            .background {
                if colorScheme == .light {
                    Color.black.opacity(Self.lightShade).ignoresSafeArea()
                }
            }
        .onChange(of: model.config.sites.map(\.id)) { _, live in
            // A service removed in settings shouldn't leave its row expanded
            // when it comes back.
            expanded.formIntersection(live)
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(status: model.overall, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(PanelHeadline.text(worst: model.overall, statuses: model.statuses))
                    .font(.headline)
                    .lineLimit(1)
                if !model.statuses.isEmpty {
                    Text(PanelHeadline.tally(model.statuses))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Group {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            // A 16-point box was smaller than the glyph drawn in it, and an
            // `Image` only takes hits where it has ink — so the corners of the
            // icon, and the gap between the arrow's ends, did nothing. The
            // frame gives the target a size worth aiming at and
            // `contentShape` makes all of it live.
            .frame(width: Self.hitTarget, height: Self.hitTarget)
            .contentShape(.rect)
        }
        // Glass, like the footer's pair: the list scrolls under the header
        // too, so this is the same kind of control floating over the same
        // moving content. Circular because it is icon-only, which is the shape
        // Liquid Glass gives a lone symbol button.
        .panelGlassButtonStyle()
        .buttonBorderShape(.circle)
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
                    .buttonStyle(.glassProminent)
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
            // No indicator, on purpose. On a Mac set to "Show scroll bars:
            // Always", an `NSScrollView` pays for its scroller out of the clip
            // view's width instead of floating it over the content — measured
            // here as 303 points of row for a 320-point panel. So the first
            // row that grew the list past the cap narrowed every row and slid
            // the right-hand status column left, mid-click. Wheel and trackpad
            // scrolling are untouched; the web build dropped its bar the same
            // way, with a zero-width `::-webkit-scrollbar`.
            .scrollIndicators(.never)
            // Soft under the header, hard under the footer. The footer has
            // bare text in it — the reading's age — and the soft effect only
            // fades what passes beneath, which left that caption printed over
            // whatever row was scrolled there. The hard style gives the bar an
            // edge the content stops at.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
    }

    /// Not lazy: a menu bar panel holds a handful of rows, and a `LazyVStack`
    /// only pays off past a screenful.
    ///
    /// The rows sit on one inset platter, the grouped-list shape System
    /// Settings and Control Center use, so the services read as one block
    /// distinct from the header and footer floating over it. The platter
    /// declares itself the container shape, which is what lets each row's
    /// `ConcentricRectangle` come out concentric with it rather than with the
    /// popover's much larger corners.
    ///
    /// Rows keep the order set in settings rather than floating trouble to the
    /// top: the order is the user's, and a row that jumped every time a page
    /// changed state would move under the pointer between two clicks. The
    /// tinted row and the headline already say where to look.
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
        .padding(Self.platterInset)
        .background(platterFill, in: .rect(cornerRadius: Self.platterRadius))
        .containerShape(.rect(cornerRadius: Self.platterRadius))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private static let platterRadius: CGFloat = 14
    private static let platterInset: CGFloat = 4

    /// A lift, not a card. White over the shaded light panel, a faint white
    /// over the dark one — the semantic fills (`.quinary` and friends) darken
    /// in light mode, which reads as a hole in the panel rather than a
    /// surface on it.
    ///
    /// Light is kept to a third: at half, the platter came out close to paper
    /// white against the shaded glass, brighter than anything else in the menu
    /// bar and enough to make the panel look lit from inside.
    private var platterFill: Color {
        colorScheme == .light ? .white.opacity(0.32) : .white.opacity(0.07)
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
    ///
    /// Glass rather than the borderless accessory-bar style: the list scrolls
    /// under the footer, and a control floating over moving content is what
    /// Liquid Glass is for. The container is what lets the two share one
    /// sampling pass, so they read as a pair of the same material.
    ///
    /// Icon-only circles, like the header's refresh. As labelled capsules the
    /// pair took a full-width band for two actions you reach for rarely; the
    /// freed space carries the reading's age, which moved down here from the
    /// header to make room for the tally. Both keep their names as tooltips
    /// and accessibility labels, and their shortcuts.
    private var footer: some View {
        HStack(spacing: 8) {
            if let updated = model.statuses.compactMap(\.fetchedAt).max() {
                // Relative and self-updating, which a formatted clock time
                // never was: "Updated 4 minutes ago" is the thing you actually
                // want to know about a cached reading.
                Text("Updated \(updated, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            GlassEffectContainer {
                HStack(spacing: 8) {
                    Button {
                        openSettingsWindow()
                    } label: {
                        iconLabel("Settings…", systemImage: "gearshape")
                    }
                    .panelGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(",")
                    .help("Settings…")

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        iconLabel("Quit AIStat", systemImage: "power")
                    }
                    .panelGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .keyboardShortcut("q")
                    .help("Quit AIStat")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A `Label` shown icon-only, so VoiceOver still reads its title, sized
    /// like the refresh button for the reason given at ``hitTarget``.
    private func iconLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .frame(width: Self.hitTarget, height: Self.hitTarget)
            .contentShape(.rect)
    }
}

private extension View {
    /// Clear glass rather than the regular variant `.glass` gives. The panel
    /// is itself a pale translucent sheet, and regular glass brightens what it
    /// samples, so on a light menu bar the three buttons came out as near-white
    /// slabs sitting well above the panel's own grey. Clear glass keeps the
    /// lensing and the edge highlight without the frosting, and so sits at the
    /// panel's tone instead of above it.
    ///
    /// `GlassButtonStyle(_:)` arrived in 26.1; on 26.0 there is only the
    /// regular one.
    @ViewBuilder
    func panelGlassButtonStyle() -> some View {
        if #available(macOS 26.1, *) {
            buttonStyle(.glass(.clear))
        } else {
            buttonStyle(.glass)
        }
    }
}
