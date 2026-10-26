import CoachKit
import CoachUI
import SwiftUI
import UIKit

/// A moment waiting to be shown over the app.
struct PendingMoment: Identifiable {
  let id: String
  let record: SessionRecord
  let display: MomentDisplay
}

/// Cross-tab state: selected tab, the Plan form, the onboarding gate and the moment trigger.
@MainActor
final class AppModel: ObservableObject {
  enum Tab { case home, plan, history }

  @Published var tab: Tab = .home
  @Published var setup: SetupModel = AppModel.loadSetup()
  @Published private(set) var onboarded: Bool
  @Published var pendingMoment: PendingMoment?
  @Published private(set) var notifyChoice: NotifyChoice
  /// What iOS allows, re-read on every foreground: it can change in iOS Settings.
  @Published private(set) var notifyAuth: NotifyAuthorization = .notDetermined
  /// Bumped to open the weekly summary from a notification tap.
  @Published private(set) var summaryRequest = 0
  /// Onboarding was skipped before the watch app was confirmed, and the nudge has not been dismissed.
  @Published private(set) var watchNudge: Bool

  private let defaults = UserDefaults.standard
  private static let seenKey = "momentsSeen"


  init(existingSessionIds: [String] = []) {
    let d = UserDefaults.standard
    // Someone who already has sessions on the phone has been through setup; remember it so deleting them all does not bring onboarding back.
    let has = !existingSessionIds.isEmpty
    onboarded = d.bool(forKey: "onboarded") || has
    notifyChoice = WeeklyNotifier.storedChoice
    watchNudge = d.object(forKey: "onboarding.watchChecked") as? Bool == false && !d.bool(forKey: "onboarding.watchNudgeDismissed")
    if has { d.set(true, forKey: "onboarded") }
    // First run of a build with moments: the sessions already here are history, not news.
    if d.object(forKey: Self.seenKey) == nil, has { d.set(existingSessionIds, forKey: Self.seenKey) }
  }

  var raceSetup: RaceSetup { RaceSetup(division: setup.division, targetSeconds: setup.targetSeconds) }

  // MARK: Plan form

  func setupChanged() {
    defaults.set(setup.division.rawValue, forKey: "setup.division")
    defaults.set(setup.targetSeconds, forKey: "setup.target")
    defaults.set(setup.type.rawValue, forKey: "setup.type")
    defaults.set(setup.wallBallReps, forKey: "setup.wbReps")
  }

  /// Home's CTA and the onboarding result: preset the Plan tab with this session type and open it.
  func start(_ type: SessionType) {
    setup.type = type
    setup.send = .idle
    setupChanged()
    tab = .plan
  }

  private static func loadSetup() -> SetupModel {
    let d = UserDefaults.standard
    var m = SetupModel()
    if let r = d.string(forKey: "setup.division"), let v = Division(rawValue: r) { m.division = v }
    if let r = d.string(forKey: "setup.type"), let v = SessionType(rawValue: r) { m.type = v }
    if PlanBuilder.focusRepOptions.contains(d.integer(forKey: "setup.wbReps")) { m.wallBallReps = d.integer(forKey: "setup.wbReps") }
    if d.integer(forKey: "setup.target") > 0 { m.targetSeconds = d.integer(forKey: "setup.target") }
    return m
  }

  // MARK: Onboarding

  /// `.skipped` still lands on Plan with the recommended session, but never counts as the watch-install check being done.
  func finishOnboarding(_ model: OnboardingModel, outcome: OnboardingOutcome) {
    defaults.set(outcome == .built, forKey: "onboarding.watchChecked")
    watchNudge = outcome != .built
    setup.division = model.division
    setup.targetSeconds = model.targetSeconds
    defaults.set(true, forKey: "onboarded")
    onboarded = true
    start(.halfSim)
  }

  /// The watch app was seen on this phone: the install check is done for good, so the nudge never comes back.
  func watchDetected() {
    guard watchNudge else { return }
    defaults.set(true, forKey: "onboarding.watchChecked")
    watchNudge = false
  }

  func dismissWatchNudge() {
    defaults.set(true, forKey: "onboarding.watchNudgeDismissed")
    watchNudge = false
  }

  // MARK: Weekly summary

  var notifyState: NotifySettingState { NotifySettingState(choice: notifyChoice, auth: notifyAuth) }

  /// A notification tap or the Home card: show the last complete week.
  func openWeekSummary() {
    tab = .home
    summaryRequest += 1
  }

  /// Foreground: iOS may have changed what it allows. Scheduling follows by itself.
  func refreshNotifyAuth() {
    Task {
      notifyAuth = await WeeklyNotifier.shared.authorization()
      PhoneTransfer.shared.rescheduleNotice()
    }
  }

  /// The Plan-tab switch, and "Yes, Mondays" on the summary card. Turning it on records the wish first, then asks iOS or sends
  /// the athlete to Settings. Declining the iOS prompt is not a permanent no: the wish stays, and granting later schedules again.
  func setNotify(_ on: Bool) {
    guard on else {
      store(notifyState.turnedOff().choice)
      PhoneTransfer.shared.rescheduleNotice()
      return
    }
    let turned = notifyState.turnedOn()
    store(turned.state.choice)
    switch turned.action {
    case .askSystem:
      Task {
        let granted = await WeeklyNotifier.shared.requestPermission()
        notifyAuth = turned.state.afterPrompt(granted: granted).auth
        PhoneTransfer.shared.rescheduleNotice()
      }
    case .openSystemSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    case .nothing:
      PhoneTransfer.shared.rescheduleNotice()
    }
  }

  /// "No thanks" on the one-time card.
  func declineNotifyCard() { store(notifyState.declinedCard().choice) }

  private func store(_ choice: NotifyChoice) {
    defaults.set(choice.rawValue, forKey: WeeklyNotifier.defaultsKey)
    notifyChoice = choice
  }

  // MARK: Moments

  /// Offer the newest unseen session its moment, once. Called whenever the synced sessions change.
  func evaluateMoments(_ records: [SessionRecord]) {
    guard onboarded, pendingMoment == nil else { return }
    let seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
    let result = MomentTrigger.evaluate(records: records, seen: seen)
    guard !result.markSeen.isEmpty else { return }
    defaults.set(Array(seen.union(result.markSeen)), forKey: Self.seenKey)
    guard let o = result.outcome else { return }
    let display = MomentDisplay.make(
      o.moment, totalSeconds: o.record.result.totalSeconds, fadeSeconds: o.record.fade,
      previousDate: o.previousBestDate.map { HistoryFormat.dayMonth($0) }, sessionType: o.record.type)
    pendingMoment = PendingMoment(id: o.record.id, record: o.record, display: display)
  }
}
