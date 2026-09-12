import AIStatCore

/// The one line the panel exists to show.
///
/// It names the service, not just the state: "Partial outage at Claude"
/// answers the question you opened the panel with, where "Partial outage" is
/// only half of it.
///
/// A free function rather than a computed property on the view, because this is
/// the panel's only real piece of logic and it has edge cases worth pinning
/// down — the plural tail, an aggregate nothing reported, an empty list.
enum PanelHeadline {
    static func text(worst: Status, statuses: [SiteStatus]) -> String {
        guard !statuses.isEmpty else { return "Nothing monitored" }
        switch worst {
        case .operational:
            return "All systems operational"
        case .unknown:
            // Nothing came back from anywhere; there is no service to name.
            return "Status unavailable"
        default:
            guard let named = statuses.first(where: { $0.overall == worst }) else {
                return worst.shortLabel
            }
            // The named service is one of those at the worst level — that's
            // what the sentence is about — and the count covers everything else
            // that isn't fine.
            //
            // "Not fine" includes `unknown` here, unlike the colour rules: a
            // status page we couldn't read is a thing the user should be told
            // about, even though it doesn't deserve a colour of its own.
            let others = statuses.filter { $0.id != named.id && $0.overall != .operational }.count
            return others > 0
                ? "\(worst.shortLabel) at \(named.name) +\(others)"
                : "\(worst.shortLabel) at \(named.name)"
        }
    }
}
