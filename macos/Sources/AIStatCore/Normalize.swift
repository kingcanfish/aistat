import Foundation

/// Maps provider-specific status vocabularies onto ``Status``.
///
/// StatusPage reference: <https://metastatuspage.com/api> (every Atlassian
/// Statuspage serves the same docs at `/api`). The public v2 API defines four
/// closed value sets, quoted below. Anything outside them maps to
/// ``Status/unknown`` rather than being guessed at.
///
/// FlashDuty reference: <https://docs.flashduty.com/zh/on-call/statuspage/widgets>
public enum Normalize {
    /// Maps the page-level `status.indicator`.
    ///
    /// Documented values — `none` (All Systems Operational), `minor` (Minor
    /// issues present), `major` (Significant service disruption), `critical`
    /// (Severe outage affecting core functionality).
    ///
    /// Statuspage describes this field as "calculated from a blend of component
    /// statuses (or an optional override)". The override is the reason a page
    /// can advertise `minor` while its component table shows partial outages,
    /// and why ``StatusPageProvider`` takes the worst of both.
    ///
    /// `maintenance` is not in the public spec; incident.io-hosted pages emit
    /// it, so it is accepted here.
    public static func statuspageIndicator(_ v: String) -> Status {
        switch v {
        case "none": .operational
        case "minor": .degraded
        case "major": .partialOutage
        case "critical": .fullOutage
        case "maintenance": .maintenance
        default: .unknown
        }
    }

    /// Maps an incident's `impact`.
    ///
    /// Documented values, with the colours Statuspage's own UI uses — `none`
    /// (black, "No user impact"), `minor` (yellow), `major` (orange),
    /// `critical` (red).
    ///
    /// This deliberately differs from ``statuspageIndicator(_:)`` on `none`. At
    /// page level `none` means "all systems operational"; on an incident it
    /// means the impact has not been classified — and Statuspage itself renders
    /// it black, never the operational green. `summary.json` returns only
    /// unresolved incidents, so such an incident is still open.
    public static func statuspageIncidentImpact(_ v: String) -> Status {
        switch v {
        case "none", "": .unknown
        case "minor": .degraded
        case "major": .partialOutage
        case "critical": .fullOutage
        default: .unknown
        }
    }

    /// Maps a component's `status`.
    ///
    /// Documented values — `operational` (Full functionality),
    /// `degraded_performance` (Reduced performance), `partial_outage` (Some
    /// features unavailable), `major_outage` (Component entirely down).
    ///
    /// `under_maintenance` is absent from the public v2 docs but is a real
    /// component state in Statuspage's management API, so it is accepted here.
    public static func statuspageComponent(_ v: String) -> Status {
        switch v {
        case "operational": .operational
        case "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage": .fullOutage
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    /// Scheduled-maintenance `status` values that mean "happening right now".
    ///
    /// Documented lifecycle — `scheduled`, `in_progress`, `verifying`,
    /// `completed`.
    public static func statuspageMaintenanceIsActive(_ v: String) -> Bool {
        v == "in_progress" || v == "verifying"
    }

    /// Maps a FlashDuty widget `overall.status` / event `impact`.
    ///
    /// Documented values — `operational`, `degraded`, `partial_outage`,
    /// `full_outage`, `maintenance`. The extra spellings are tolerated because
    /// the widget is also used by self-hosted Flashcat pages.
    public static func flashduty(_ v: String) -> Status {
        switch v {
        case "operational": .operational
        case "degraded", "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage", "full_outage": .fullOutage
        case "maintenance", "under_maintenance": .maintenance
        default: .unknown
        }
    }
}
