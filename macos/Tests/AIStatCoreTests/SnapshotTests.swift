import Testing

@testable import AIStatCore

@Suite("Snapshot diffing")
struct SnapshotTests {
    func site(_ id: String, _ overall: Status, _ incidentIDs: [String] = []) -> SiteStatus {
        SiteStatus(
            id: id, name: id, url: "https://status.example.com", adapter: "statuspage",
            overall: overall,
            incidents: incidentIDs.map {
                Incident(id: $0, title: "t", impact: .unknown, lifecycle: "identified", latestUpdate: "")
            }
        )
    }

    @Test func detectsStatusChange() {
        let before = ["a": site("a", .operational)]
        let changes = detectChanges(before: before, after: [site("a", .fullOutage)])
        #expect(changes.count == 1)
        #expect(changes[0].newOverall == .fullOutage)
        #expect(changes[0].oldOverall == .operational)
    }

    @Test func detectsNewIncident() {
        let before = ["a": site("a", .operational)]
        let changes = detectChanges(before: before, after: [site("a", .operational, ["inc-1"])])
        #expect(changes.count == 1)
        #expect(changes[0].newIncidents.count == 1)
    }

    @Test func noChangeIsEmpty() {
        let before = ["a": site("a", .operational, ["inc-1"])]
        #expect(detectChanges(before: before, after: [site("a", .operational, ["inc-1"])]).isEmpty)
    }

    /// The first reading of a site is a baseline, not a change — at launch, and
    /// when one is added. Firing here would mean every open incident on every
    /// service arrives as a notification the moment the app starts.
    @Test func aSiteWithNoPreviousReadingNeverFires() {
        #expect(detectChanges(before: [:], after: [site("a", .operational)]).isEmpty)
        #expect(detectChanges(before: [:], after: [site("a", .fullOutage, ["inc-1"])]).isEmpty)
    }

    /// ...but the reading it establishes is still a baseline, so the *next*
    /// fetch reports against it.
    @Test func theSecondFetchReportsAgainstTheFirst() {
        let first = site("a", .fullOutage, ["inc-1"])
        #expect(detectChanges(before: [:], after: [first]).isEmpty)

        let before = [first.id: first]
        let changes = detectChanges(before: before, after: [site("a", .fullOutage, ["inc-1", "inc-2"])])
        #expect(changes.count == 1)
        #expect(changes[0].newIncidents.map(\.id) == ["inc-2"])
    }

    /// A resolved incident disappearing is not a new incident.
    @Test func aDisappearingIncidentIsNotReported() {
        let before = ["a": site("a", .degraded, ["inc-1"])]
        let changes = detectChanges(before: before, after: [site("a", .degraded)])
        #expect(changes.isEmpty)
    }
}
