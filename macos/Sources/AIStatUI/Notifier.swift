import AIStatCore
import UserNotifications

/// Desktop notifications on a status change.
///
/// The Rust build's notification code was mostly a workaround: `notify-rust` on
/// macOS needs a Launch Services–registered bundle identifier to post at all,
/// and if nothing had named one by the first `show()` it ran an AppleScript
/// lookup that opened the system "Choose Application" picker in the user's
/// face — at the exact moment a site went down. The whole `claim_notification_identity`
/// dance existed to spend that one-shot before it could fire.
///
/// `UNUserNotificationCenter` takes the identity from the running bundle, so
/// none of that applies. What it wants instead is authorization, asked for once
/// and remembered by the system.
enum Notifier {
    /// Asks once, at launch. A refusal is final and silent — the user said no,
    /// and a status change is not the moment to argue about it.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, error in
            if let error {
                Log.app.warning(
                    "notification authorization failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                Log.app.info("notifications \(granted ? "allowed" : "refused", privacy: .public)")
            }
        }
    }

    /// One notification per changed site. The body names the incident when
    /// there is one, because "Claude — Partial Outage" without it leaves the
    /// user to open the panel to learn anything.
    static func post(_ change: StatusChange) {
        let content = UNMutableNotificationContent()
        content.title = "\(change.siteName) — \(change.newOverall.label)"
        if let incident = change.newIncidents.first {
            content.body = [incident.title, incident.latestUpdate]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            content.body =
                "Status changed from \(change.oldOverall.label) to \(change.newOverall.label)"
        }
        content.sound = .default

        // Identified by site so a second change replaces the first rather than
        // stacking three notices for one wobbling service.
        let request = UNNotificationRequest(
            identifier: "aistat.\(change.siteID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.warning(
                    "could not post a notification for \(change.siteName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
