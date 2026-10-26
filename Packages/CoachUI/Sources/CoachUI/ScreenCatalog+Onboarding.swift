import CoachKit
import SwiftUI

/// Batch B screens. D joins `onboardingScreens` into `ScreenCatalog.all`.
@MainActor
public extension ScreenCatalog {
  private static func phoneFull(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view.frame(width: Theme.phone.width, height: Theme.phone.height)))
  }

  private static func card(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view))
  }

  static var onboardingScreens: [CatalogEntry] {
    let model = OnboardingModel(division: .openMen, targetSeconds: 5400, watchAppInstalled: true)
    var missing = model
    missing.watchAppInstalled = false
    let full = SampleData.result(extra: [4: 45, 5: 41, 13: 18])
    let partial = SampleData.result(extra: [4: 30], until: 10)
    let halfPlan = PlanBuilder.build(division: .openMen, target: 5400, type: .halfSim)
    var t: Int64 = 0
    let halfSplits: [StepSplit] = halfPlan.steps.map { step in
      defer { t += Int64(step.targetSeconds) * 1000 }
      return StepSplit(stepIndex: step.index, startMs: t, endMs: t + Int64(step.targetSeconds) * 1000)
    }
    let half = CoachResult(plan: halfPlan, splits: halfSplits, early: false, repTimesMs: [], repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: t)
    let date = "Sat 24 Oct"

    let first = MomentDisplay.make(.first(.fullSim), totalSeconds: 4904, fadeSeconds: 27)
    let firstHalf = MomentDisplay.make(.first(.halfSim), totalSeconds: 2410, fadeSeconds: 18)
    let firstPartial = MomentDisplay.make(.first(.fullSim), totalSeconds: 2975, fadeSeconds: 27, partial: (done: 5, of: 8))
    let best = MomentDisplay.make(.best(.fullSim, previousBest: 4864), totalSeconds: 4702, fadeSeconds: nil, previousDate: "24 Oct")
    let leastFade = MomentDisplay.make(.leastFade(previous: 27), totalSeconds: 4800, fadeSeconds: 19, sessionType: .fullSim)

    return [
      phoneFull("onboarding-intro", OnboardingIntroScreen()),
      phoneFull("onboarding-race", OnboardingRaceScreen(model: model)),
      phoneFull("onboarding-watch", OnboardingWatchScreen(model: model)),
      phoneFull("onboarding-watch-missing", OnboardingWatchScreen(model: missing)),
      phoneFull("moment-first-full", MomentScreen(display: first, result: full, animate: false)),
      phoneFull("moment-first-half", MomentScreen(display: firstHalf, result: half, animate: false)),
      phoneFull("moment-first-partial", MomentScreen(display: firstPartial, result: partial, animate: false)),
      phoneFull("moment-best", MomentScreen(display: best, result: full, animate: false)),
      phoneFull("moment-least-fade", MomentScreen(display: leastFade, result: full, animate: false)),
      card("sharecard-v2-full", ShareCardV2(result: full, dateText: date)),
      card("sharecard-v2-partial", ShareCardV2(result: partial, dateText: date)),
      card("sharecard-v2-moment-best", ShareCardV2(result: full, dateText: date, moment: best)),
      card("sharecard-v2-moment-first-partial", ShareCardV2(result: partial, dateText: date, moment: firstPartial)),
      card("sharecard-v2-moment-first", ShareCardV2(result: full, dateText: date, moment: first)),
    ]
  }
}
