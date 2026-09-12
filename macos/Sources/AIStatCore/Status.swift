import Foundation

/// Unified status vocabulary shared by every provider.
///
/// The raw values are the JSON wire format, and they are deliberately the same
/// snake_case strings the Rust build serialized: a `config.json` written by the
/// Tauri version still loads here.
public enum Status: String, Codable, Sendable, CaseIterable, Hashable {
    case operational
    case degraded
    case partialOutage = "partial_outage"
    case fullOutage = "full_outage"
    case maintenance
    case unknown

    /// Default aggregation priority, most severe first.
    ///
    /// `maintenance` outranks `degraded` on purpose: planned work is a thing
    /// the user should see named, not something to hide behind a wobble.
    public static let defaultPriority: [Status] = [
        .fullOutage, .partialOutage, .maintenance, .degraded, .operational, .unknown,
    ]

    /// Severity index within `priority` (lower is more severe). A status absent
    /// from the list ranks least severe rather than crashing the comparison.
    public func severity(in priority: [Status]) -> Int {
        priority.firstIndex(of: self) ?? Int.max
    }

    /// Human readable label for UI display.
    public var label: String {
        switch self {
        case .operational: "Operational"
        case .degraded: "Degraded"
        case .partialOutage: "Partial Outage"
        case .fullOutage: "Full Outage"
        case .maintenance: "Maintenance"
        case .unknown: "Unknown"
        }
    }

    /// The shorter form the panel uses in rows, where "Partial Outage" and
    /// "Partial outage" sit next to a service name and only one of them reads
    /// as a reading rather than a title.
    public var shortLabel: String {
        switch self {
        case .partialOutage: "Partial outage"
        case .fullOutage: "Full outage"
        default: label
        }
    }
}

/// Aggregates statuses into the single "worst" one under `priority`.
/// An empty input is `unknown` — nothing was measured, which is not the same
/// as everything being fine.
public func aggregate(_ statuses: some Sequence<Status>, priority: [Status]) -> Status {
    statuses.reduce(Status.unknown) { acc, s in
        s.severity(in: priority) < acc.severity(in: priority) ? s : acc
    }
}
