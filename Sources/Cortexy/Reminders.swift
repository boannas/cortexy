import AppKit
import UserNotifications

/// Notifications for tasks with a due date (`- [ ] … 📅 2026-10-05 14:30`; without a time, at the hour set in
/// Settings). Rescheduled from scratch after edits; macOS keeps 64 per app, so the nearest 60 are set.
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    var open: (UUID) -> Void = { _ in }

    /// The notification center needs a real app bundle; outside one (`swift test`, `swift run`) it crashes.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil }

    func start() { center?.delegate = self }

    static func fireDate(_ t: Nav.DueTask) -> Date {
        t.hasTime ? t.date : Calendar.current.date(byAdding: .hour, value: Int(Prefs.number(Prefs.remindAt)), to: t.date) ?? t.date
    }

    func schedule(_ tasks: [Nav.DueTask], titles: [UUID: String]) {
        guard let center else { return }
        let on = (UserDefaults.standard.object(forKey: Prefs.reminders) as? Bool) ?? true
        let now = Date()
        let soon = on ? Array(tasks.filter { !$0.done && Self.fireDate($0) > now }.sorted { Self.fireDate($0) < Self.fireDate($1) }.prefix(60)) : []
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus != .notDetermined else {
                // Asked once, the first time there's something to remind about.
                if !soon.isEmpty { center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { Self.add(soon, titles, center) } } }
                return
            }
            Self.add(soon, titles, center)
        }
    }

    private static func add(_ tasks: [Nav.DueTask], _ titles: [UUID: String], _ center: UNUserNotificationCenter) {
        center.removeAllPendingNotificationRequests()
        for t in tasks {
            let content = UNMutableNotificationContent()
            content.title = t.text.isEmpty ? "A task is due" : t.text
            content.body = titles[t.nid] ?? ""
            content.sound = .default
            content.userInfo = ["note": t.nid.uuidString, "line": t.line]
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate(t))
            center.add(UNNotificationRequest(identifier: "task-" + t.id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a reminder opens its note.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let s = r.notification.request.content.userInfo["note"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run { open(id) }
    }
}
