import CoachKit
import Foundation
import UserNotifications

/// The Monday 08:00 weekly-load notification. What it says and when it fires is `WeeklyNotice.plan`, and whether it may fire is
/// `NotifySettingState` (both CoachKit, tested); this only talks to the system. Local notifications need no entitlement.
/// Only one notification is ever scheduled ahead (not repeating): if the app is not opened for a week, the next Monday has
/// nothing, which fits "never nag".
@MainActor
final class WeeklyNotifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = WeeklyNotifier()
  static let defaultsKey = "notify.weekly"

  private let center = UNUserNotificationCenter.current()
  /// Set by the root view; a tap that arrives before it exists (a cold launch) waits in `pendingOpen`.
  var onOpenSummary: (() -> Void)?
  private var pendingOpen = false
  private var generation = 0

  /// What iOS allows right now. Provisional and ephemeral count as allowed.
  func authorization() async -> NotifyAuthorization {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    default: return .authorized
    }
  }

  /// Shows the iOS prompt. True when granted.
  func requestPermission() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  static var storedChoice: NotifyChoice {
    NotifyChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .undecided
  }

  /// Cancel the old one and schedule the next. Reads the athlete's choice and iOS's answer itself, so every caller (a sync in
  /// the background, a foreground, the Plan switch) gets the same behaviour. The text is built from the sessions on the phone
  /// now. Sessions still on the watch are not counted: `watchHasUnsent` adds the caveat.
  func reschedule(sessions: [LoadSession], watchHasUnsent: Bool, now: Date = Date()) {
    generation += 1
    let mine = generation
    Task {
      let auth = await authorization()
      guard mine == generation else { return }
      center.removePendingNotificationRequests(withIdentifiers: [WeeklyNotice.Scheduled.identifier])
      let state = NotifySettingState(choice: Self.storedChoice, auth: auth)
      guard let plan = WeeklyNotice.plan(sessions: sessions, now: now, calendar: LoadHistory.calendar(), optedIn: state.isScheduling,
                                         watchHasUnsent: watchHasUnsent) else { return }
      let content = UNMutableNotificationContent()
      content.title = plan.content.title
      content.body = plan.content.body
      content.sound = .default
      let trigger = UNCalendarNotificationTrigger(dateMatching: plan.fire, repeats: false)
      try? await center.add(UNNotificationRequest(identifier: WeeklyNotice.Scheduled.identifier, content: content, trigger: trigger))
    }
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
