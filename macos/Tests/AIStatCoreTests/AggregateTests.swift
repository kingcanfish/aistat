import Testing

@testable import AIStatCore

@Suite("Aggregation")
struct AggregateTests {
    let priority = Status.defaultPriority

    @Test func picksTheMostSevere() {
        #expect(aggregate([.operational, .degraded], priority: priority) == .degraded)
        #expect(
            aggregate([.operational, .fullOutage, .degraded], priority: priority) == .fullOutage)
        #expect(aggregate([.operational, .operational], priority: priority) == .operational)
    }

    /// Nothing measured is not the same as everything being fine.
    @Test func emptyIsUnknown() {
        #expect(aggregate([Status](), priority: priority) == .unknown)
    }

    @Test func maintenanceBeatsDegraded() {
        #expect(aggregate([.degraded, .maintenance], priority: priority) == .maintenance)
    }

    @Test func unknownRanksLast() {
        #expect(aggregate([.operational, .unknown], priority: priority) == .operational)
    }

    /// A status missing from the configured priority must not win by accident.
    @Test func aStatusOutsideThePriorityRanksLeastSevere() {
        let partial: [Status] = [.fullOutage, .operational]
        #expect(aggregate([.operational, .degraded], priority: partial) == .operational)
    }
}

@Suite("Normalization")
struct NormalizeTests {
    /// Locks in the four documented value sets, so a typo in one of the arms
    /// can't silently downgrade a real outage to Unknown.
    @Test func coversEveryDocumentedStatuspageValue() {
        for (value, want) in [
            ("none", Status.operational), ("minor", .degraded),
            ("major", .partialOutage), ("critical", .fullOutage),
        ] {
            #expect(Normalize.statuspageIndicator(value) == want, "indicator \(value)")
        }

        for (value, want) in [
            ("none", Status.unknown), ("minor", .degraded),
            ("major", .partialOutage), ("critical", .fullOutage),
        ] {
            #expect(Normalize.statuspageIncidentImpact(value) == want, "impact \(value)")
        }

        for (value, want) in [
            ("operational", Status.operational), ("degraded_performance", .degraded),
            ("partial_outage", .partialOutage), ("major_outage", .fullOutage),
        ] {
            #expect(Normalize.statuspageComponent(value) == want, "component \(value)")
        }

        for (value, active) in [
            ("scheduled", false), ("in_progress", true),
            ("verifying", true), ("completed", false),
        ] {
            #expect(Normalize.statuspageMaintenanceIsActive(value) == active, "maintenance \(value)")
        }
    }

    @Test func unrecognizedValuesAreUnknownNotOperational() {
        #expect(Normalize.statuspageIndicator("something_new") == .unknown)
        #expect(Normalize.statuspageIncidentImpact("something_new") == .unknown)
        #expect(Normalize.statuspageComponent("something_new") == .unknown)
        #expect(Normalize.flashduty("something_new") == .unknown)
    }

    @Test func mapsFlashdutyStatuses() {
        #expect(Normalize.flashduty("operational") == .operational)
        #expect(Normalize.flashduty("degraded") == .degraded)
        #expect(Normalize.flashduty("degraded_performance") == .degraded)
        #expect(Normalize.flashduty("partial_outage") == .partialOutage)
        #expect(Normalize.flashduty("full_outage") == .fullOutage)
        #expect(Normalize.flashduty("major_outage") == .fullOutage)
        #expect(Normalize.flashduty("maintenance") == .maintenance)
    }
}
