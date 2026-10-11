import Foundation
import Observation
import UserNotifications

/// Posts a macOS notification when an agent finishes its turn or starts waiting on you.
/// Compares each session's live state with the previous check, so only transitions notify.
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var enabled: Bool = UserDefaults.standard.bool(forKey: "notify") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notify")
            if enabled { requestAuthorization() }
        }
    }
    /// False once macOS has told us notifications are denied for AgentLens.
    private(set) var allowed = true

    @ObservationIgnored private var last: [String: Phase] = [:]
    @ObservationIgnored private var seeded = false

    private enum Phase { case working, waiting, finished, idle }

    /// UNUserNotificationCenter needs an app bundle; the bare binary (--dump, swift run) has none.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        if enabled { requestAuthorization() }
    }

    private func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in Notifier.shared.allowed = granted }
        }
    }

    func check(_ sessions: [SessionSummary], now: Date) {
        var next: [String: Phase] = [:]
        for s in sessions {
            let state = s.live(at: now)
            let phase: Phase
            switch state {
            case .running, .thinking: phase = .working
            case .waitingOnYou: phase = .waiting
            case .finished: phase = .finished
            case .idle: phase = .idle
            }
            next[s.id] = phase
            // The first pass only records where things stand; it shouldn't replay old news.
            guard seeded, enabled, let before = last[s.id], before != phase else { continue }
            switch (before, state) {
            case (.working, .finished):
                post(s, title: "\(s.title) finished", body: "Your turn. \(s.place)")
            case (_, .waitingOnYou(let reason, _)):
                post(s, title: "\(s.title) is waiting on you", body: reason)
            default: break
            }
        }
        last = next
        seeded = true
    }

    private func post(_ s: SessionSummary, title: String, body: String) {
        guard available, allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": s.id]
        // One notification per session: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: s.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the popover or dashboard has focus.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens that session in the dashboard.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in AppController.shared.openDashboard(select: id) }
        completionHandler()
    }
}
