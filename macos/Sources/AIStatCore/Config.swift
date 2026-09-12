import Foundation

public enum AdapterKind: String, Codable, Sendable, CaseIterable {
    case statuspage
    case flashduty
}

/// How the menu bar icon expresses status.
///
/// The three are genuinely different trades, not three skins, so the choice is
/// the user's: how much of the menu bar's quiet the icon is allowed to spend.
public enum IconStyle: String, Codable, Sendable, CaseIterable {
    /// The mark gets louder as the news gets worse: monochrome while healthy,
    /// tinted when degraded, filled when something is down. Weight survives
    /// peripheral vision in a way hue alone does not.
    case escalating
    /// Monochrome glyph in every state, status carried by the corner lamp
    /// alone. The quietest of the three, and the hardest to read at a glance.
    case lamp
    /// The whole glyph carries the status colour in every state, healthy
    /// included. One rule to learn, at the cost of colour in the bar all day.
    case tinted

    public var menuTitle: String {
        switch self {
        case .escalating: "Louder when worse"
        case .lamp: "Corner lamp only"
        case .tinted: "Always tinted"
        }
    }
}

public struct SiteConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var adapter: AdapterKind

    public init(id: String, name: String, url: String, adapter: AdapterKind) {
        self.id = id
        self.name = name
        self.url = url
        self.adapter = adapter
    }

    /// The id the settings sheet derives from a typed name, matching what the
    /// web panel did so an edited config keeps its ids stable across versions.
    public static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII ? ch : "-"
        }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var refreshIntervalSeconds: UInt64
    public var notificationsEnabled: Bool
    public var launchAtLogin: Bool
    public var statusPriority: [Status]
    public var iconStyle: IconStyle
    public var sites: [SiteConfig]

    /// Wire names are the Rust build's, so an existing `config.json` migrates
    /// with no conversion step.
    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds = "refresh_interval_seconds"
        case notificationsEnabled = "notifications_enabled"
        case launchAtLogin = "launch_at_login"
        case statusPriority = "status_priority"
        case iconStyle = "icon_style"
        case sites
    }

    /// Anything below this and a poll loop is hammering the upstream pages
    /// rather than watching them. Mirrors the floor the scheduler enforces.
    public static let minimumInterval: UInt64 = 30
    public static let defaultInterval: UInt64 = 300

    public static let defaultSites: [SiteConfig] = [
        SiteConfig(id: "claude", name: "Claude", url: "https://status.claude.com", adapter: .statuspage),
        SiteConfig(id: "openai", name: "OpenAI", url: "https://status.openai.com", adapter: .statuspage),
        SiteConfig(id: "deepseek", name: "DeepSeek", url: "https://status.deepseek.com", adapter: .flashduty),
    ]

    public init(
        refreshIntervalSeconds: UInt64 = Config.defaultInterval,
        notificationsEnabled: Bool = true,
        launchAtLogin: Bool = false,
        statusPriority: [Status] = Status.defaultPriority,
        iconStyle: IconStyle = .escalating,
        sites: [SiteConfig] = Config.defaultSites
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.notificationsEnabled = notificationsEnabled
        self.launchAtLogin = launchAtLogin
        self.statusPriority = statusPriority
        self.iconStyle = iconStyle
        self.sites = sites
    }

    /// Every field is optional on the way in, the way `#[serde(default)]` made
    /// them in Rust: a config written by an older build, or hand-edited with a
    /// key missing, still loads instead of reverting the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        refreshIntervalSeconds =
            try c.decodeIfPresent(UInt64.self, forKey: .refreshIntervalSeconds)
            ?? defaults.refreshIntervalSeconds
        notificationsEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
            ?? defaults.notificationsEnabled
        launchAtLogin =
            try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        statusPriority =
            try c.decodeIfPresent([Status].self, forKey: .statusPriority) ?? defaults.statusPriority
        iconStyle = try c.decodeIfPresent(IconStyle.self, forKey: .iconStyle) ?? defaults.iconStyle
        // An explicit empty list is a real answer ("monitor nothing"), so this
        // only fills in when the key is absent entirely.
        sites = try c.decodeIfPresent([SiteConfig].self, forKey: .sites) ?? defaults.sites
    }

    /// The interval the scheduler actually sleeps for.
    public var effectiveInterval: UInt64 { max(refreshIntervalSeconds, Config.minimumInterval) }

    public static func fromJSON(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
