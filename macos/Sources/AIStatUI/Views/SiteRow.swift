import AIStatCore
import SwiftUI

/// One watched service, expandable into its incidents and components.
struct SiteRow: View {
    var site: SiteStatus
    var isExpanded: Bool
    var toggle: () -> Void

    @State private var hovering = false

    /// Concentric with whatever contains the row rather than a fixed 7 points.
    /// The panel's corners grew with Liquid Glass, and a hard-coded inner radius
    /// that matched the old popover reads as a mismatch against the new one.
    /// The minimum is what the row had before, so where no container shape
    /// reaches it — an offscreen render, say — nothing changes.
    static let shape = ConcentricRectangle(corners: .concentric(minimum: 7), isUniform: true)

    private var attentionCount: Int {
        site.incidents.isEmpty ? site.impairedComponents.count : site.incidents.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded {
                // Near-symmetric rather than hung off the favicon's left edge.
                // The deep indent it used to have pushed the whole block right
                // of centre, and left the right-aligned component readings
                // sitting further right than the summary row's own status —
                // two columns that look like they should line up and don't.
                detail
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            }
        }
        .background(rowFill, in: Self.shape)
        .onHover { hovering = $0 }
    }

    /// A collapsed row in trouble keeps a faint wash of its status colour, so
    /// it stands out of a list of quiet rows without being moved to the top.
    ///
    /// Collapsed only. Open, the row is a tall block full of status-coloured
    /// text — component readings, the incident rails — and those are the same
    /// hue as the wash: system yellow on a yellow ground was close to
    /// invisible. An open row takes the neutral grey every other row does, the
    /// ground that text was tuned against.
    private var rowFill: AnyShapeStyle {
        if site.overall.isNoteworthy && !isExpanded {
            return AnyShapeStyle(site.overall.tint.opacity(hovering ? 0.16 : 0.1))
        }
        return AnyShapeStyle(.quinary.opacity(isExpanded ? 1 : (hovering ? 0.8 : 0)))
    }

    /// A quiet row carries a small status symbol on the right; a row in trouble
    /// carries its state as a solid pill there instead, with what it amounts to
    /// on a second line. Five rows all saying "Operational" was the panel
    /// shouting the one thing that needs no saying, and pushed the one that did
    /// into the same column as the rest.
    ///
    /// The symbol, not a plain dot: shape carries the state here, not hue alone
    /// (see `Status.symbolName`). The pill is solid for legibility: system
    /// yellow as text does not read on a light panel at any wash, but dark
    /// text on a yellow fill does, in either appearance — and a filled shape
    /// is the one mark in the list loud enough to find at a glance.
    private var summary: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                SiteIcon(site: site)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.name)
                        .fontWeight(site.overall.isNoteworthy ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        subtitle
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if site.overall.isNoteworthy {
                    StatusPill(status: site.overall)
                } else {
                    StatusBadge(status: site.overall, size: 12)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 7 : 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(site.name), \(site.overall.label)")
        .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
    }

    /// The second line, for a row that has something to say: how much is wrong
    /// — the state itself is in the pill — or why it couldn't be read. `nil`
    /// for a quiet row, and for one in trouble with nothing to count.
    ///
    /// Folds in what used to be a separate count badge, which said "2" and
    /// left the hover tooltip to say two of what.
    ///
    /// A `Text` rather than a `String`: the plural is inflection markup, and
    /// only a `LocalizedStringKey` — what a `Text` literal is — renders it.
    /// `String(localized:)` hands back the markup verbatim.
    private var subtitle: Text? {
        if site.overall.isNoteworthy {
            guard attentionCount > 0 else { return nil }
            return site.incidents.isEmpty
                ? Text("^[\(attentionCount) component](inflect: true) affected")
                : Text("^[\(attentionCount) open incident](inflect: true)")
        }
        return site.error == nil ? nil : Text("Can't reach status page")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = site.error {
                Label {
                    Text("Can't reach this status page. \(error)")
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Incidents first: they're what you opened the panel to read.
            if !site.incidents.isEmpty {
                SectionLabel("Incidents")
                ForEach(site.incidents) { IncidentCard(incident: $0) }
            } else if !site.impairedComponents.isEmpty {
                // Providers often flip component statuses without filing an
                // incident; say so rather than leaving the section blank.
                Text(
                    "^[\(site.impairedComponents.count) component](inflect: true) degraded with no incident filed."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !site.components.isEmpty {
                SectionLabel("Components")
                // Worst first, so problems don't hide at the bottom of a long list.
                ForEach(
                    site.components.sorted {
                        $0.status.severity(in: Status.defaultPriority)
                            < $1.status.severity(in: Status.defaultPriority)
                    }
                ) { component in
                    ComponentRow(component: component)
                }
            }

            Link(destination: URL(string: site.url) ?? AppInfo.repositoryURL) {
                Label("Open status page", systemImage: "arrow.up.forward.app")
            }
            .font(.callout)
            .padding(.top, 2)
        }
    }
}

/// One component line. Its own view so each line can track its own hover.
@MainActor
private struct ComponentRow: View {
    var component: Component

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: component.status.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(component.status.tint)
            // Provider component names run long and the panel is 320 points
            // wide, so a long one is clipped next to its status label —
            // "Codex in Ch…PT Desktop" beside "Partial outage", unreadable
            // exactly when it matters. Hovering the line scrolls the rest into
            // view; the tooltip stays for Reduce Motion, where it cannot.
            MarqueeText(text: component.name, scrolling: hovering)
                .help(component.name)
            Spacer(minLength: 8)
            Text(component.status.shortLabel)
                .foregroundStyle(component.status.foreground)
                .layoutPriority(1)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}

/// Carded, with the impact colour as a rail down its edge — the rail sizes
/// itself to the card, so a long incident is marked for its whole height.
struct IncidentCard: View {
    var incident: Incident

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(incident.impact.tint)
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(incident.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty {
                    // Metadata stays at 10pt: it is the one line here you read
                    // past rather than read.
                    Text(meta).font(.caption).foregroundStyle(.tertiary)
                }
                if !incident.latestUpdate.isEmpty {
                    Text(incident.latestUpdate)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Incident text is the one thing here worth pasting
                        // into a ticket.
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .padding(.leading, 6)
        // Concentric too, though inset this deep the concentric radius is
        // below the minimum and the card keeps its old 6 points. The row can't
        // hand it a tighter container: `containerShape` takes only fixed
        // rounded rectangles, not a `ConcentricRectangle`.
        .background(
            .quaternary.opacity(0.55),
            in: ConcentricRectangle(corners: .concentric(minimum: 6), isUniform: true)
        )
    }

    private var meta: String {
        var parts: [String] = []
        if !incident.lifecycle.isEmpty { parts.append(incident.lifecycle.capitalized) }
        if let raw = incident.updatedAt, let date = Self.parse(raw) {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    /// Providers timestamp in RFC 3339, with and without fractional seconds.
    static func parse(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// The service's own mark, scraped from the page's `<link rel=icon>`, with a
/// lettered chip standing in until (or unless) it loads.
///
/// Deliberately colourless: the status symbol is the only thing in a row
/// allowed to carry colour, so a favicon's brand hue can't be mistaken for it.
struct SiteIcon: View {
    var site: SiteStatus

    private var monogram: String {
        String(site.name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
    }

    var body: some View {
        Group {
            if let icon = site.icon, let url = URL(string: icon) {
                AsyncImage(url: url) { image in
                    image.resizable().interpolation(.high).scaledToFit()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
    }

    /// Larger than it was, now that the status symbol has left the front of the
    /// row: the icon is what the eye finds a service by.
    private static let size: CGFloat = 20
    private static let radius: CGFloat = 5

    private var placeholder: some View {
        Text(monogram)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: Self.size, height: Self.size)
            .background(.quaternary, in: .rect(cornerRadius: Self.radius, style: .continuous))
    }
}
