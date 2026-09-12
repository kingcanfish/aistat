import AIStatCore
import ServiceManagement

/// Start at login.
///
/// The Rust build carried a `launch_at_login` field in its config that nothing
/// ever read — the setting existed in the file and did nothing. `SMAppService`
/// makes it three lines, so this is one place where going native adds a feature
/// rather than porting one: registering the app itself, with no helper bundle,
/// no login item plist and no `LSSharedFileList` deprecation to work around.
///
/// The user can still revoke it in System Settings → General → Login Items, so
/// ``isEnabled`` reads the live status rather than trusting the config file.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("launch at login: \(enabled ? "on" : "off", privacy: .public)")
        } catch {
            // Registering fails for a loose binary — `swift run` has no bundle
            // for Launch Services to register — which is worth a line but not a
            // dialog: the switch simply won't stick outside a real .app.
            Log.app.warning(
                "could not \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
