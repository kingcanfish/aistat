import Foundation

/// Atlassian Statuspage public API v2. Schema and field values are documented
/// at `<page>/api`, e.g. <https://metastatuspage.com/api>.
///
/// `summary.json` returns the page indicator, every component, all *unresolved*
/// incidents, and upcoming plus in-progress maintenances in one request.
public enum StatusPageProvider {
    public static let summaryPath = "/api/v2/summary.json"

    // Every field is optional on the way in: these pages are hosted by two
    // different vendors (Atlassian and incident.io) and neither promises the
    // keys the other omits.
    struct Summary: Decodable {
        var status = StatusBlock()
        var components: [ComponentRaw] = []
        var incidents: [IncidentRaw] = []
        var scheduledMaintenances: [MaintenanceRaw] = []

        enum CodingKeys: String, CodingKey {
            case status, components, incidents
            case scheduledMaintenances = "scheduled_maintenances"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(StatusBlock.self, forKey: .status) ?? StatusBlock()
            components = try c.decodeIfPresent([ComponentRaw].self, forKey: .components) ?? []
            incidents = try c.decodeIfPresent([IncidentRaw].self, forKey: .incidents) ?? []
            scheduledMaintenances =
                try c.decodeIfPresent([MaintenanceRaw].self, forKey: .scheduledMaintenances) ?? []
        }

        init() {}
    }

    struct StatusBlock: Decodable {
        var indicator = ""
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            indicator = try c.decodeIfPresent(String.self, forKey: .indicator) ?? ""
        }
        enum CodingKeys: String, CodingKey { case indicator }
    }

    struct ComponentRaw: Decodable {
        var name = ""
        var status: String?
        var group = false
        enum CodingKeys: String, CodingKey { case name, status, group }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status)
            group = try c.decodeIfPresent(Bool.self, forKey: .group) ?? false
        }
    }

    struct IncidentRaw: Decodable {
        var id = ""
        var name = ""
        var status = ""
        var impact = ""
        var updatedAt: String?
        var shortlink: String?
        var incidentUpdates: [UpdateRaw] = []

        enum CodingKeys: String, CodingKey {
            case id, name, status, impact, shortlink
            case updatedAt = "updated_at"
            case incidentUpdates = "incident_updates"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            impact = try c.decodeIfPresent(String.self, forKey: .impact) ?? ""
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            shortlink = try c.decodeIfPresent(String.self, forKey: .shortlink)
            incidentUpdates = try c.decodeIfPresent([UpdateRaw].self, forKey: .incidentUpdates) ?? []
        }
    }

    struct UpdateRaw: Decodable {
        var body = ""
        enum CodingKeys: String, CodingKey { case body }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        }
    }

    struct MaintenanceRaw: Decodable {
        var status = ""
        enum CodingKeys: String, CodingKey { case status }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        }
    }

    /// Fetches a StatusPage-compatible page (Atlassian Statuspage and
    /// incident.io both expose this schema) in a single `summary.json` call.
    public static func fetch(
        client: HTTPClient, site: SiteConfig
    ) async throws(ProviderError) -> SiteStatus {
        let url = site.url.trimmedTrailingSlash + summaryPath
        return toStatus(site: site, summary: try await client.fetchJSON(Summary.self, from: url))
    }

    static func toStatus(site: SiteConfig, summary: Summary) -> SiteStatus {
        let components: [Component] = summary.components
            .filter { !$0.group }
            .compactMap { raw in
                guard let status = raw.status else { return nil }
                return Component(name: raw.name, status: Normalize.statuspageComponent(status))
            }

        // The page-level indicator is maintained by hand and routinely lags the
        // component table — Anthropic's page has read "minor" while four
        // components reported a partial outage. Take the worst of every signal
        // so the menu bar never under-reports.
        let maintenanceActive = summary.scheduledMaintenances.contains {
            Normalize.statuspageMaintenanceIsActive($0.status)
        }

        var signals = [Normalize.statuspageIndicator(summary.status.indicator)]
        signals.append(contentsOf: components.map(\.status))
        if maintenanceActive { signals.append(.maintenance) }
        let overall = aggregate(signals, priority: Status.defaultPriority)

        let incidents = summary.incidents.map { raw in
            Incident(
                id: raw.id,
                title: raw.name,
                impact: Normalize.statuspageIncidentImpact(raw.impact),
                lifecycle: raw.status,
                latestUpdate: raw.incidentUpdates.last?.body ?? "",
                updatedAt: raw.updatedAt,
                url: raw.shortlink
            )
        }

        return SiteStatus(
            id: site.id, name: site.name, url: site.url, adapter: AdapterKind.statuspage.rawValue,
            overall: overall, components: components, incidents: incidents, fetchedAt: Date()
        )
    }
}

extension String {
    var trimmedTrailingSlash: String {
        var s = Substring(self)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }
}
