import Foundation
import Testing

@testable import AIStatCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite("StatusPage adapter")
struct StatusPageTests {
    let site = SiteConfig(
        id: "claude", name: "Claude", url: "https://status.claude.com", adapter: .statuspage)

    @Test func parsesSummaryAndMapsIndicator() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "page": {"id": "x", "name": "Claude", "url": "https://status.claude.com"},
              "status": {"indicator": "none", "description": "All Systems Operational"},
              "components": [
                {"id": "1", "name": "claude.ai", "status": "operational"},
                {"id": "2", "name": "Claude API", "status": "degraded_performance"}
              ],
              "incidents": [],
              "scheduled_maintenances": []
            }
            """)
        #expect(Normalize.statuspageIndicator(summary.status.indicator) == .operational)
        #expect(summary.components.count == 2)
    }

    /// status.claude.com reported indicator "minor" while four components were
    /// in partial outage. The panel must show the worse of the two.
    @Test func overallEscalatesToTheWorstComponent() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "minor"},
              "components": [
                {"id":"1","name":"Console","status":"operational"},
                {"id":"2","name":"claude.ai","status":"partial_outage"},
                {"id":"3","name":"Claude Code","status":"partial_outage"}
              ],
              "incidents": [],
              "scheduled_maintenances": []
            }
            """)
        #expect(StatusPageProvider.toStatus(site: site, summary: summary).overall == .partialOutage)
    }

    @Test func componentGroupsDoNotDriveTheOverallStatus() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "none"},
              "components": [
                {"id":"1","name":"A group","status":"major_outage","group":true},
                {"id":"2","name":"Real","status":"operational"}
              ]
            }
            """)
        let result = StatusPageProvider.toStatus(site: site, summary: summary)
        #expect(result.overall == .operational)
        #expect(result.components.count == 1)
    }

    @Test func maintenanceDoesNotDowngradeAWorseSignal() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "critical"},
              "components": [],
              "scheduled_maintenances": [{"status": "in_progress"}]
            }
            """)
        #expect(StatusPageProvider.toStatus(site: site, summary: summary).overall == .fullOutage)
    }

    @Test func inProgressMaintenanceRaisesAnOtherwiseHealthyPage() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "none"},
              "components": [{"id":"1","name":"API","status":"operational"}],
              "scheduled_maintenances": [{"status": "in_progress"}]
            }
            """)
        #expect(StatusPageProvider.toStatus(site: site, summary: summary).overall == .maintenance)
    }

    /// A *scheduled* maintenance that has not started is not happening yet.
    @Test func aScheduledMaintenanceDoesNotRaiseAnything() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {"status": {"indicator": "none"}, "scheduled_maintenances": [{"status": "scheduled"}]}
            """)
        #expect(StatusPageProvider.toStatus(site: site, summary: summary).overall == .operational)
    }

    /// An open incident with impact "none" is unclassified, not resolved.
    @Test func unclassifiedOpenIncidentsAreNotGreen() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "minor"},
              "incidents": [
                {"id":"a","name":"RBAC roles failing","status":"identified","impact":"none"},
                {"id":"b","name":"Elevated errors","status":"identified","impact":"minor"}
              ]
            }
            """)
        let result = StatusPageProvider.toStatus(site: site, summary: summary)
        #expect(result.incidents[0].impact == .unknown)
        #expect(result.incidents[1].impact == .degraded)
    }

    @Test func readsTheLatestIncidentUpdate() throws {
        let summary = try decode(
            StatusPageProvider.Summary.self,
            """
            {
              "status": {"indicator": "minor"},
              "incidents": [{
                "id":"a","name":"Elevated errors","status":"monitoring","impact":"minor",
                "updated_at":"2026-09-11T14:19:51.617Z",
                "shortlink":"https://stspg.io/abc",
                "incident_updates":[{"body":"Investigating"},{"body":"Mitigation applied"}]
              }]
            }
            """)
        let incident = StatusPageProvider.toStatus(site: site, summary: summary).incidents[0]
        #expect(incident.latestUpdate == "Mitigation applied")
        #expect(incident.url == "https://stspg.io/abc")
        #expect(incident.lifecycle == "monitoring")
    }

    /// A page missing whole sections must still parse — the two vendors serving
    /// this schema do not agree on which keys are optional.
    @Test func missingSectionsStillParse() throws {
        let summary = try decode(StatusPageProvider.Summary.self, #"{"status":{}}"#)
        let result = StatusPageProvider.toStatus(site: site, summary: summary)
        #expect(result.overall == .unknown)
        #expect(result.components.isEmpty)
    }
}

@Suite("FlashDuty adapter")
struct FlashDutyTests {
    let site = SiteConfig(
        id: "deepseek", name: "DeepSeek", url: "https://status.deepseek.com", adapter: .flashduty)

    @Test func parsesLiveShapeWithNoEvents() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self,
            """
            {
              "schema_version": "1.0",
              "generated_at": "2026-07-24T02:49:05Z",
              "poll_after_seconds": 30,
              "max_stale_seconds": 120,
              "page": {"name": "DeepSeek", "url": "https://status.deepseek.com"},
              "overall": {"status": "operational"},
              "ongoing_incidents": [],
              "in_progress_maintenances": [],
              "scheduled_maintenances": []
            }
            """)
        let result = try FlashDutyProvider.summaryToStatus(site: site, widget)
        #expect(result.overall == .operational)
        #expect(result.incidents.isEmpty)
        #expect(result.components.isEmpty)
    }

    @Test func readsDocumentedIncidentFields() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self,
            """
            {
              "overall": {"status": "partial_outage"},
              "ongoing_incidents": [{
                "id": "inc-1",
                "title": "API degraded",
                "phase": "identified",
                "impact": "degraded",
                "started_at": "2026-07-24T02:00:00Z",
                "updated_at": "2026-07-24T02:10:00Z",
                "url": "https://status.deepseek.com/incidents/inc-1",
                "last_update": {"at": "2026-07-24T02:10:00Z", "message": "Mitigation applied"},
                "affected_components": [
                  {"id": "c1", "name": "Chat", "group_name": "Web", "status": "degraded"},
                  {"id": "c2", "name": "API", "status": "partial_outage"}
                ]
              }],
              "in_progress_maintenances": [],
              "scheduled_maintenances": []
            }
            """)
        let result = try FlashDutyProvider.summaryToStatus(site: site, widget)

        #expect(result.overall == .partialOutage)
        let incident = result.incidents[0]
        #expect(incident.id == "inc-1")
        #expect(incident.lifecycle == "identified")
        #expect(incident.impact == .degraded)
        #expect(incident.latestUpdate == "Mitigation applied")
        #expect(incident.updatedAt == "2026-07-24T02:10:00Z")

        #expect(result.components.count == 2)
        #expect(result.components[0].name == "Web / Chat")
        #expect(result.components[0].status == .degraded)
        #expect(result.components[1].name == "API")
    }

    @Test func maintenanceShowsUpAsAnIncidentAndRaisesOverall() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self,
            """
            {
              "overall": {"status": "operational"},
              "ongoing_incidents": [],
              "in_progress_maintenances": [{
                "id": "m1",
                "title": "Database upgrade",
                "phase": "ongoing",
                "starts_at": "2026-07-24T01:00:00Z",
                "updated_at": "2026-07-24T01:05:00Z",
                "last_update": {"at": "2026-07-24T01:05:00Z", "message": "Started"},
                "affected_components": [{"id": "c1", "name": "API", "status": "maintenance"}]
              }]
            }
            """)
        let result = try FlashDutyProvider.summaryToStatus(site: site, widget)
        #expect(result.overall == .maintenance)
        #expect(result.incidents.count == 1)
        #expect(result.incidents[0].impact == .maintenance)
        #expect(result.incidents[0].title == "Database upgrade")
        #expect(result.components[0].name == "API")
    }

    @Test func anOutageIsNotDowngradedToMaintenance() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self,
            """
            {
              "overall": {"status": "full_outage"},
              "in_progress_maintenances": [{"id":"m1","title":"Upgrade","phase":"ongoing"}]
            }
            """)
        #expect(try FlashDutyProvider.summaryToStatus(site: site, widget).overall == .fullOutage)
    }

    /// An open event reporting "operational" impact hasn't been classified yet;
    /// showing it green would claim it's already resolved.
    @Test func anUnclassifiedOpenEventInheritsTheOverall() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self,
            """
            {
              "overall": {"status": "degraded"},
              "ongoing_incidents": [{"id":"i1","title":"","phase":"investigating","impact":"operational"}]
            }
            """)
        let incident = try FlashDutyProvider.summaryToStatus(site: site, widget).incidents[0]
        #expect(incident.impact == .degraded)
        #expect(incident.title == "Untitled incident")
    }

    @Test func errorEnvelopeBecomesAProviderError() throws {
        let widget = try decode(
            FlashDutyProvider.WidgetSummary.self, #"{"error": "status_page_not_found"}"#)
        #expect(throws: ProviderError.self) {
            try FlashDutyProvider.summaryToStatus(site: site, widget)
        }
        do {
            _ = try FlashDutyProvider.summaryToStatus(site: site, widget)
        } catch {
            #expect(error.description.contains("widget disabled"))
        }
    }
}
