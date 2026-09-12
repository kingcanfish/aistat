import Foundation
import Testing

@testable import AIStatCore

@Suite("Config")
struct ConfigTests {
    /// The wire format is the Rust build's, so an existing `config.json`
    /// migrates with no conversion step. This is the test that guards it.
    @Test func readsAConfigWrittenByTheRustBuild() throws {
        let json = """
            {
              "refresh_interval_seconds": 120,
              "notifications_enabled": false,
              "launch_at_login": true,
              "status_priority": ["full_outage", "partial_outage", "maintenance", "degraded", "operational", "unknown"],
              "icon_style": "tinted",
              "sites": [
                {"id": "claude", "name": "Claude", "url": "https://status.claude.com", "adapter": "statuspage"},
                {"id": "deepseek", "name": "DeepSeek", "url": "https://status.deepseek.com", "adapter": "flashduty"}
              ]
            }
            """
        let config = try Config.fromJSON(Data(json.utf8))
        #expect(config.refreshIntervalSeconds == 120)
        #expect(config.notificationsEnabled == false)
        #expect(config.launchAtLogin == true)
        #expect(config.iconStyle == .tinted)
        #expect(config.sites.count == 2)
        #expect(config.sites[1].adapter == .flashduty)
        #expect(config.statusPriority == Status.defaultPriority)
    }

    /// Every field was `#[serde(default)]` in Rust; a config missing a key must
    /// still load rather than reverting the whole file to defaults.
    @Test func missingKeysFallBackFieldByField() throws {
        let config = try Config.fromJSON(Data(#"{"refresh_interval_seconds": 45}"#.utf8))
        #expect(config.refreshIntervalSeconds == 45)
        #expect(config.notificationsEnabled == true)
        #expect(config.iconStyle == .escalating)
        #expect(config.sites.count == 3)
    }

    /// An explicit empty list is a real answer ("monitor nothing"), not a
    /// missing key.
    @Test func anEmptySiteListIsRespected() throws {
        let config = try Config.fromJSON(Data(#"{"sites": []}"#.utf8))
        #expect(config.sites.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var config = Config()
        config.iconStyle = .lamp
        config.refreshIntervalSeconds = 900
        let decoded = try Config.fromJSON(config.toJSON())
        #expect(decoded == config)
    }

    /// Anything below the floor is a poll loop hammering upstream rather than
    /// watching it.
    @Test func theIntervalHasAFloor() throws {
        let config = try Config.fromJSON(Data(#"{"refresh_interval_seconds": 1}"#.utf8))
        #expect(config.effectiveInterval == 30)
    }

    @Test func slugsMatchTheWebBuild() {
        #expect(SiteConfig.slug("Claude") == "claude")
        #expect(SiteConfig.slug("Hugging Face") == "hugging-face")
        #expect(SiteConfig.slug("  X.AI  ") == "x-ai")
    }

    @Test func normalizeURLAddsAScheme() {
        #expect(try! normalizeURL("status.claude.com").get() == "https://status.claude.com")
        #expect(try! normalizeURL(" https://a.com ").get() == "https://a.com")
        #expect(throws: URLProblem.self) { try normalizeURL("ftp://a.com").get() }
        #expect(throws: URLProblem.self) { try normalizeURL("  ").get() }
    }
}
