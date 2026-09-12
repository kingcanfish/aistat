import Foundation

/// A detected change in a single site between two fetches.
public struct StatusChange: Sendable, Hashable {
    public var siteID: String
    public var siteName: String
    public var oldOverall: Status
    public var newOverall: Status
    /// Newly appearing incidents (by id) since the previous snapshot.
    public var newIncidents: [Incident]
}

/// Compares a fresh batch against the previous snapshot and returns one
/// ``StatusChange`` per site whose overall status moved or that gained new
/// incidents. This is what drives notifications.
///
/// A site with no previous reading produces nothing at all — not even for the
/// incidents it already has open. There is nothing to compare against, so
/// nothing has *changed*, and the setting this feeds says "notify when a
/// service changes state". That covers the two cases where it matters: the
/// first fetch after launch, which would otherwise announce every open incident
/// on every service at once, and a service the user has only just added, whose
/// current state they are looking at as they add it.
public func detectChanges(
    before: [String: SiteStatus],
    after: [SiteStatus]
) -> [StatusChange] {
    after.compactMap { curr in
        guard let prev = before[curr.id] else { return nil }

        let statusChanged = prev.overall != curr.overall
        let previousIDs = Set(prev.incidents.map(\.id))
        let newIncidents = curr.incidents.filter { !previousIDs.contains($0.id) }

        guard statusChanged || !newIncidents.isEmpty else { return nil }
        return StatusChange(
            siteID: curr.id,
            siteName: curr.name,
            oldOverall: prev.overall,
            newOverall: curr.overall,
            newIncidents: newIncidents
        )
    }
}
