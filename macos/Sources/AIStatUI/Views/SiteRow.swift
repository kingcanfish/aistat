import AIStatCore
import SwiftUI

/// One watched service, expandable into its incidents and components.
struct SiteRow: View {
    var site: SiteStatus
    var isExpanded: Bool
    var toggle: () -> Void

    @State private var hovering = false

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
        .background(
            .quinary.opacity(isExpanded ? 1 : (hovering ? 0.8 : 0)),
            in: .rect(cornerRadius: 7, style: .continuous)
        )
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                StatusBadge(status: site.overall)
                SiteIcon(site: site)
                Text(site.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if attentionCount > 0 {
                    Text(attentionCount, format: .number)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(site.overall.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(site.overall.tint.opacity(0.18), in: .capsule)
                        .help(attentionHelp)
                }

                Text(site.overall.shortLabel)
                    .font(.callout)
                    .foregroundStyle(site.overall.foreground)
                    .lineLimit(1)
                    // The reading wins the space: a long service name truncates
                    // before "Partial outage" is allowed to.
                    .layoutPriority(1)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(site.name), \(site.overall.label)")
        .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
    }

    private var attentionHelp: String {
        site.incidents.isEmpty
            ? "^[\(site.impairedComponents.count) component](inflect: true) affected"
            : "^[\(site.incidents.count) open incident](inflect: true)"
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
                    HStack(spacing: 5) {
                        Image(systemName: component.status.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(component.status.tint)
                        Text(component.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Provider component names run long and the panel
                            // is 320 points wide; hovering is how you read the
                            // rest of one.
                            .help(component.name)
                        Spacer(minLength: 8)
                        Text(component.status.shortLabel)
                            .foregroundStyle(component.status.foreground)
                            .layoutPriority(1)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
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
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 6, style: .continuous))
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
        .frame(width: 15, height: 15)
        .clipShape(.rect(cornerRadius: 3.5, style: .continuous))
    }

    private var placeholder: some View {
        Text(monogram)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
            .background(.quaternary, in: .rect(cornerRadius: 3.5, style: .continuous))
    }
}
