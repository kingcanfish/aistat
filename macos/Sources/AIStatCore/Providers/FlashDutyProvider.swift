import Foundation

/// FlashDuty / Flashcat status page widget adapter.
///
/// Schema: <https://docs.flashduty.com/zh/on-call/statuspage/widgets>
/// `GET {page}/api/widget/v1/summary.json`, public and CORS-enabled.
public enum FlashDutyProvider {
    public static let widgetPath = "/api/widget/v1/summary.json"

    public struct WidgetSummary: Decodable {
        public var overall = OverallBlock()
        public var ongoingIncidents: [Event] = []
        public var inProgressMaintenances: [Event] = []
        public var scheduledMaintenances: [Event] = []
        /// Set on the documented error envelopes (`status_page_not_found`,
        /// `widget_summary_unavailable`), which come back with a JSON body and
        /// an otherwise ordinary 200.
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case overall, error
            case ongoingIncidents = "ongoing_incidents"
            case inProgressMaintenances = "in_progress_maintenances"
            case scheduledMaintenances = "scheduled_maintenances"
        }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            overall = try c.decodeIfPresent(OverallBlock.self, forKey: .overall) ?? OverallBlock()
            ongoingIncidents = try c.decodeIfPresent([Event].self, forKey: .ongoingIncidents) ?? []
            inProgressMaintenances =
                try c.decodeIfPresent([Event].self, forKey: .inProgressMaintenances) ?? []
            scheduledMaintenances =
                try c.decodeIfPresent([Event].self, forKey: .scheduledMaintenances) ?? []
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }
    }

    public struct OverallBlock: Decodable {
        public var status: String?
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status)
        }
        enum CodingKeys: String, CodingKey { case status }
    }

    /// Both incidents and maintenances use this shape; only a few fields differ.
    public struct Event: Decodable {
        public var id = ""
        public var title = ""
        /// investigating / identified / monitoring, or scheduled / ongoing.
        public var phase = ""
        public var impact: String?
        public var updatedAt: String?
        public var startsAt: String?
        public var url: String?
        public var lastUpdate: LastUpdate?
        public var affectedComponents: [AffectedComponent] = []

        enum CodingKeys: String, CodingKey {
            case id, title, phase, impact, url
            case updatedAt = "updated_at"
            case startsAt = "starts_at"
            case lastUpdate = "last_update"
            case affectedComponents = "affected_components"
        }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
            impact = try c.decodeIfPresent(String.self, forKey: .impact)
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            startsAt = try c.decodeIfPresent(String.self, forKey: .startsAt)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            lastUpdate = try c.decodeIfPresent(LastUpdate.self, forKey: .lastUpdate)
            affectedComponents =
                try c.decodeIfPresent([AffectedComponent].self, forKey: .affectedComponents) ?? []
        }

        func intoIncident(fallbackImpact: Status) -> Incident {
            // An open event reporting "operational" impact hasn't been
            // classified yet; showing it green would claim it's already
            // resolved.
            let mapped = impact.map(Normalize.flashduty)
            let resolvedImpact =
                (mapped == nil || mapped == .unknown || mapped == .operational)
                ? fallbackImpact : mapped!

            return Incident(
                id: id,
                title: title.isEmpty ? "Untitled incident" : title,
                impact: resolvedImpact,
                lifecycle: phase,
                latestUpdate: lastUpdate?.message ?? "",
                updatedAt: updatedAt ?? lastUpdate?.at ?? startsAt,
                url: url
            )
        }
    }

    public struct LastUpdate: Decodable {
        public var at: String?
        public var message: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try c.decodeIfPresent(String.self, forKey: .at)
            message = try c.decodeIfPresent(String.self, forKey: .message)
        }
        enum CodingKeys: String, CodingKey { case at, message }
    }

    public struct AffectedComponent: Decodable {
        public var name = ""
        public var groupName: String?
        public var status: String?
        enum CodingKeys: String, CodingKey {
            case name, status
            case groupName = "group_name"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
            status = try c.decodeIfPresent(String.self, forKey: .status)
        }
    }

    /// Components aren't published as a standalone list; the widget only names
    /// the ones an active event touches, so that's what we surface.
    static func components(from events: [Event]) -> [Component] {
        var out: [Component] = []
        var seen = Set<String>()
        for event in events {
            for c in event.affectedComponents where !c.name.isEmpty {
                let name: String
                if let group = c.groupName, !group.isEmpty {
                    name = "\(group) / \(c.name)"
                } else {
                    name = c.name
                }
                guard seen.insert(name).inserted else { continue }
                out.append(
                    Component(name: name, status: c.status.map(Normalize.flashduty) ?? .unknown))
            }
        }
        return out
    }

    public static func summaryToStatus(
        site: SiteConfig, _ w: WidgetSummary
    ) throws(ProviderError) -> SiteStatus {
        if let err = w.error {
            switch err {
            case "status_page_not_found":
                throw ProviderError.parse("status page not found, private, or widget disabled")
            case "widget_summary_unavailable":
                throw ProviderError.parse("widget data temporarily unavailable")
            default:
                throw ProviderError.parse(err)
            }
        }

        var overall = w.overall.status.map(Normalize.flashduty) ?? .unknown

        // Planned work that is happening now is worth naming, but it must never
        // pull a real outage back up to blue.
        if !w.inProgressMaintenances.isEmpty && overall == .operational {
            overall = .maintenance
        }

        let components =
            components(from: w.ongoingIncidents) + components(from: w.inProgressMaintenances)

        let incidentFallback: Status = overall == .operational ? .unknown : overall
        var incidents = w.ongoingIncidents.map { $0.intoIncident(fallbackImpact: incidentFallback) }
        incidents += w.inProgressMaintenances.map { $0.intoIncident(fallbackImpact: .maintenance) }

        return SiteStatus(
            id: site.id, name: site.name, url: site.url, adapter: AdapterKind.flashduty.rawValue,
            overall: overall, components: components, incidents: incidents, fetchedAt: Date()
        )
    }

    /// Fetches a FlashDuty/Flashcat status page via its public widget JSON API.
    public static func fetch(
        client: HTTPClient, site: SiteConfig
    ) async throws(ProviderError) -> SiteStatus {
        let url = site.url.trimmedTrailingSlash + widgetPath
        let w = try await client.fetchJSON(WidgetSummary.self, from: url)
        return try summaryToStatus(site: site, w)
    }
}
