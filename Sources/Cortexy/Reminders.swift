import AppKit
import UserNotifications

/// Notifications for tasks with a due date (`- [ ] … 📅 2026-10-05 14:30`; without a time, at the hour set in
/// Settings). Rescheduled from scratch after edits; macOS keeps 64 per app, so the nearest 60 are set.
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    var open: (UUID, Int?) -> Void = { _, _ in }

    /// The notification center needs a real app bundle; outside one (`swift test`, `swift run`) it crashes.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil }

    func start() {
        center?.delegate = self
        // Snooze buttons on each reminder.
        let actions = Snooze.allCases.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title) }
        center?.setNotificationCategories([UNNotificationCategory(identifier: "task", actions: actions, intentIdentifiers: [])])
    }

    enum Snooze: String, CaseIterable {
        case minutes10 = "snooze.10m", hour = "snooze.1h", tomorrow = "snooze.tomorrow"
        var title: String { switch self { case .minutes10: "In 10 Minutes"; case .hour: "In 1 Hour"; case .tomorrow: "Tomorrow" } }
        /// When it comes back: tomorrow is at the reminder hour set in Settings.
        func date(from now: Date = Date()) -> Date {
            switch self {
            case .minutes10: return now.addingTimeInterval(600)
            case .hour: return now.addingTimeInterval(3600)
            case .tomorrow:
                let cal = Calendar.current
                return cal.date(byAdding: .hour, value: Int(Prefs.number(Prefs.remindAt)), to: cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!))!
            }
        }
    }

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
        // Snoozed ones stay (they were asked for), the rest is set afresh.
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !$0.hasPrefix("snooze-") })
            addFresh(tasks, titles, center)
        }
    }

    private static func addFresh(_ tasks: [Nav.DueTask], _ titles: [UUID: String], _ center: UNUserNotificationCenter) {
        for t in tasks {
            let content = UNMutableNotificationContent()
            content.title = t.text.isEmpty ? "A task is due" : t.text
            content.body = titles[t.nid] ?? ""
            content.sound = .default
            content.userInfo = ["note": t.nid.uuidString, "line": t.line]
            content.categoryIdentifier = "task"
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate(t))
            center.add(UNNotificationRequest(identifier: "task-" + t.id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a reminder opens its note at the task; a snooze button brings it back later.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let content = r.notification.request.content
        if let snooze = Snooze(rawValue: r.actionIdentifier) {
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: snooze.date())
            try? await c.add(UNNotificationRequest(identifier: "snooze-" + UUID().uuidString, content: content,
                                                   trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            return
        }
        guard let s = content.userInfo["note"] as? String, let id = UUID(uuidString: s) else { return }
        let line = content.userInfo["line"] as? Int
        await MainActor.run { open(id, line) }
    }
}
