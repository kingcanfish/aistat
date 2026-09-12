import OSLog

/// Unified-logging channels, one per layer.
///
/// This replaces the Rust build's `env_logger` + `AISTAT_LOG` env var. A menu
/// bar app launched from Finder has no terminal to print to, so stderr was only
/// ever useful when the user re-ran the binary by hand; `os.Logger` is readable
/// either way:
///
/// ```sh
/// log stream --predicate 'subsystem == "com.aistat.app"' --level debug
/// ```
public enum Log {
    public static let subsystem = "com.aistat.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let icon = Logger(subsystem: subsystem, category: "icon")
    public static let tray = Logger(subsystem: subsystem, category: "tray")
}
