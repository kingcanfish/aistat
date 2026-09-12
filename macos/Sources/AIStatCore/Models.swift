import Foundation

public struct Component: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var status: Status

    public var id: String { name }

    public init(name: String, status: Status) {
        self.name = name
        self.status = status
    }
}

public struct Incident: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var impact: Status
    /// Incident lifecycle (investigating / identified / monitoring / resolved).
    public var lifecycle: String
    /// Latest update/description text.
    public var latestUpdate: String
    public var updatedAt: String?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case id, title, impact, lifecycle
        case latestUpdate = "latest_update"
        case updatedAt = "updated_at"
        case url
    }

    public init(
        id: String, title: String, impact: Status, lifecycle: String,
        latestUpdate: String, updatedAt: String? = nil, url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.impact = impact
        self.lifecycle = lifecycle
        self.latestUpdate = latestUpdate
        self.updatedAt = updatedAt
        self.url = url
    }
}

public struct SiteStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var adapter: String
    public var overall: Status
    public var components: [Component]
    public var incidents: [Incident]
    public var fetchedAt: Date?
    /// Verbatim failure text for the row to show. Non-nil implies `.unknown`.
    public var error: String?
    /// Absolute URL of the page's own icon, resolved separately from the status
    /// API and filled in by the caller. `nil` means "fall back to a monogram".
    public var icon: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, adapter, overall, components, incidents
        case fetchedAt = "fetched_at"
        case error, icon
    }

    public init(
        id: String, name: String, url: String, adapter: String, overall: Status,
        components: [Component] = [], incidents: [Incident] = [],
        fetchedAt: Date? = nil, error: String? = nil, icon: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.adapter = adapter
        self.overall = overall
        self.components = components
        self.incidents = incidents
        self.fetchedAt = fetchedAt
        self.error = error
        self.icon = icon
    }

    /// A per-site failure, rendered as a row rather than failing the batch.
    public static func fromError(site: SiteConfig, message: String) -> SiteStatus {
        SiteStatus(
            id: site.id, name: site.name, url: site.url,
            adapter: site.adapter.rawValue, overall: .unknown,
            fetchedAt: Date(), error: message
        )
    }

    /// The components that are not operational. Providers routinely flip these
    /// without filing an incident, so this is what the panel falls back to when
    /// it has a degraded service and nothing to read about it.
    public var impairedComponents: [Component] {
        components.filter { $0.status != .operational }
    }
}
