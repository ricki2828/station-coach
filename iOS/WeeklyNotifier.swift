import CoachKit
import Foundation
import UserNotifications

/// The Monday 08:00 weekly-load notification. What it says and when it fires is `WeeklyNotice.plan` (CoachKit, tested);
/// this only talks to the system. Local notifications need no entitlement.
final class WeeklyNotifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = WeeklyNotifier()

  private let center = UNUserNotificationCenter.current()
  /// Set by the root view; a tap that arrives before it exists (a cold launch) waits in `pendingOpen`.
  var onOpenSummary: (() -> Void)?
  private var pendingOpen = false

  /// True when the system granted permission.
  func requestPermission() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  /// Cancel the old one and schedule the next. Called after every sync and every foreground, because the text is built from
  /// the sessions on the phone now. Sessions still on the watch are not counted.
  func reschedule(sessions: [LoadSession], optedIn: Bool, now: Date = Date()) {
    center.removePendingNotificationRequests(withIdentifiers: [WeeklyNotice.Scheduled.identifier])
    guard let plan = WeeklyNotice.plan(sessions: sessions, now: now, calendar: LoadHistory.calendar(), optedIn: optedIn) else { return }
    let content = UNMutableNotificationContent()
    content.title = plan.content.title
    content.body = plan.content.body
    content.sound = .default
    let trigger = UNCalendarNotificationTrigger(dateMatching: plan.fire, repeats: false)
    center.add(UNNotificationRequest(identifier: WeeklyNotice.Scheduled.identifier, content: content, trigger: trigger))
  }

  /// A tap that landed before the root view was ready.
  func consumePendingOpen() -> Bool {
    defer { pendingOpen = false }
    return pendingOpen
  }

  private func opened() {
    if let onOpenSummary { onOpenSummary() } else { pendingOpen = true }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard response.notification.request.identifier == WeeklyNotice.Scheduled.identifier else { return }
    await MainActor.run { WeeklyNotifier.shared.opened() }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner]
  }
}
