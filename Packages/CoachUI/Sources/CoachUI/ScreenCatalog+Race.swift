import CoachKit
import SwiftUI

/// Race day and skip-station watch screens, merged into `ScreenCatalog.watchScreens` (so the five-size sweep renders them).
@MainActor
enum RaceScreens {
  private static func watch(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "watch-\(name)", size: Theme.watch46, view: AnyView(WatchChrome { view }),
                 sized: { size in AnyView(WatchChrome(size: size) { view }) })
  }

  private static func step(_ kind: StepScreenModel.Kind, _ a: Activity, _ title: String, badge: String? = nil, dominant: String,
                           secondary: String, next: String, delta: Int, toast: String? = nil) -> StepScreenModel {
    StepScreenModel(kind: kind, activity: a, title: title, badge: badge, dominant: dominant, dominantLabel: "", secondary: secondary,
                    secondaryLabel: "", next: next, deltaSeconds: delta, hrBpm: 142, toast: toast,
                    ladder: LadderTick.ladder(for: SampleData.plan, done: Set(0..<6), current: 6))
  }

  static var watchScreens: [CatalogEntry] {
    let run = step(.run, .run, "Run 4", dominant: "3:12", secondary: "/ 5:24", next: "Next: Burpee broad jumps", delta: 8)
    let changeover = step(.run, .run, "Run 4", badge: "Changeover", dominant: "0:21", secondary: "/ 5:24", next: "Next: Burpee broad jumps", delta: 8)
    let station = step(.time, .sledPush, "Sled push", dominant: "2:10", secondary: "/ 4:02", next: "Next: Run 3", delta: -14)
    let walls = StepScreenModel(kind: .reps, activity: .wallBalls, title: "Wall balls", dominant: "45", dominantLabel: "", secondary: "Set 4 \u{00B7} 15",
                                secondaryLabel: "", next: "", isLast: true, deltaSeconds: 32, hrBpm: 142,
                                ladder: LadderTick.ladder(for: SampleData.plan, done: Set(0..<15), current: 15))
    var skippedToast = run
    skippedToast.toast = CoachCopy.skippedToast(SampleData.plan.steps[9])
    var movedToast = run
    movedToast.toast = CoachCopy.movedToast(SampleData.plan.steps[9], after: SampleData.plan.steps[11])
    let all = FinishScreenModel.stations(from: SampleData.result(extra: [1: -25, 5: 41]))
    var skipped = SampleData.result()
    skipped.splits[9].skipped = true // the Row, skipped
    let rowStep = SampleData.plan.steps[9]
    return [
      watch("ready-race", CoachReadyScreen(model: .ready(ReadyInfo(sessionName: "Race day", targetText: "1:20:00", line: "Splits are estimates")))),
      watch("race-run", CoachStepScreen(model: run, onMissed: {})),
      watch("race-changeover", CoachStepScreen(model: changeover, onMissed: {})),
      watch("race-station", CoachStepScreen(model: station, onMissed: {})),
      watch("race-wallballs", CoachStepScreen(model: walls, onMissed: {})),
      watch("menu-station", CoachMenuScreen(canSkip: true)),
      watch("skip-confirm", CoachSkipConfirmScreen(title: CoachCopy.skipTitle(rowStep), activity: rowStep.activity, canLater: true)),
      watch("skip-confirm-race", CoachSkipConfirmScreen(title: CoachCopy.skipTitle(rowStep), activity: rowStep.activity, canLater: false)),
      watch("toast-skip", CoachStepScreen(model: skippedToast, onMissed: {})),
      watch("toast-skip-later", CoachStepScreen(model: movedToast, onMissed: {})),
      watch("skip-leftover", CoachLeftoverScreen(title: CoachCopy.leftoverTitle(rowStep), activity: rowStep.activity)),
      watch("finish-race-under", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:19:02", line: "0:58 under target", early: false, best: "Row \u{2212}0:25", worst: "Sled pull +0:41",
        totalSeconds: 4742, stations: all), animate: false)),
      watch("finish-skipped", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:12:40", line: "1 station skipped", early: false,
        totalSeconds: 4360, stations: FinishScreenModel.stations(from: skipped)), animate: false)),
    ]
  }
}
