import CoachKit
import CoachUI
import SwiftUI

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

  private let defaults = UserDefaults.standard
  private static let seenKey = "momentsSeen"

  init(hasSessions: Bool = false) {
    // Someone who already has sessions on the phone has been through setup.
    onboarded = UserDefaults.standard.bool(forKey: "onboarded") || hasSessions
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

  func finishOnboarding(_ model: OnboardingModel) {
    setup.division = model.division
    setup.targetSeconds = model.targetSeconds
    defaults.set(true, forKey: "onboarded")
    onboarded = true
    start(.halfSim)
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
