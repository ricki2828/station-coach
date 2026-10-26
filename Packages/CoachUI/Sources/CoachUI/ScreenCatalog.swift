import CoachKit
import SwiftUI

/// Synthetic sessions for previews and the CI screenshots.
public enum SampleData {
  public static let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)

  /// A finished session where each step took its target plus `extra[index]`; `until` stops early.
  public static func result(extra: [Int: Int] = [:], until: Int? = nil, rest: Int = 20) -> CoachResult {
    var t: Int64 = 0
    var splits: [StepSplit] = []
    for step in plan.steps {
      if let until, step.index >= until { break }
      let d = Int64(step.targetSeconds + (extra[step.index] ?? 0)) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    var reps: [Int64] = []
    if until == nil {
      var r: Int64 = (splits.first { plan.steps[$0.stepIndex].activity == .wallBalls }?.startMs ?? 0) + 1_000
      for size in Stations.wallBallSets(reps: 100) {
        for _ in 0..<size { reps.append(r); r += 2_000 }
        r += Int64(rest - 2) * 1000
      }
    }
    return CoachResult(plan: plan, splits: splits, early: until != nil, repTimesMs: reps, repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: t)
  }
}

public struct CatalogEntry {
  public let name: String
  public let size: CGSize?
  public let view: AnyView
}

/// Every screen state, by name, for the screenshot tests. Watch screens are 46 mm (208 x 248 pt).
@MainActor
public enum ScreenCatalog {
  private static func watch(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "watch-\(name)", size: Theme.watch46, view: AnyView(WatchChrome { view }))
  }

  private static func phone(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view))
  }

  private static func step(_ kind: StepScreenModel.Kind, _ a: Activity, _ title: String, badge: String? = nil, dominant: String,
                           dominantLabel: String, secondary: String, secondaryLabel: String, next: String, isLast: Bool = false,
                           delta: Int, hr: Int? = 142, toast: String? = nil, alarm: String? = nil, approx: Bool = false) -> StepScreenModel {
    StepScreenModel(kind: kind, activity: a, title: title, badge: badge, dominant: dominant, dominantLabel: dominantLabel,
                    secondary: secondary, secondaryLabel: secondaryLabel, next: next, isLast: isLast, deltaSeconds: delta,
                    hrBpm: hr, toast: toast, alarm: alarm, approximate: approx)
  }

  public static var watchScreens: [CatalogEntry] {
    let allStations = FinishScreenModel.stations(from: SampleData.result(extra: [1: -25, 5: 41]))
    let earlyStations = FinishScreenModel.stations(from: SampleData.result(until: 10))
    let ready = ReadyInfo(sessionName: "Full sim", targetText: "1:20:00", athleteChip: "A1 \u{00B7} L")
    let run = step(.run, .run, "Run 4", dominant: "3:12", dominantLabel: "Run time 3 minutes 12", secondary: "/ 5:24",
                   secondaryLabel: "Target 5 minutes 24", next: "Next: Burpee broad jumps", delta: -20)
    let station = step(.time, .skierg, "SkiErg", dominant: "2:10", dominantLabel: "Station time 2 minutes 10", secondary: "/ 4:25",
                       secondaryLabel: "Target 4 minutes 25", next: "Next: Run 2", delta: -14)
    let walls = step(.reps, .wallBalls, "Wall balls", dominant: "45", dominantLabel: "Reps left, 45", secondary: "Set 4 \u{00B7} 15",
                     secondaryLabel: "Set 4 of 7, 15 reps", next: "", isLast: true, delta: 32)
    var lowConf = walls
    lowConf.approximate = true
    var over = run
    over.deltaSeconds = 32
    over.dominant = "5:41"
    var sled = step(.time, .sledPull, "Sled pull", dominant: "1:48", dominantLabel: "Station time 1 minute 48", secondary: "/ 4:25",
                    secondaryLabel: "Target 4 minutes 25", next: "Next: Run 4", delta: 8)
    sled.hrBpm = 171
    return [
      watch("ready-loading", CoachReadyScreen(model: .loading)),
      watch("ready-no-plan", CoachReadyScreen(model: .noPlan)),
      watch("ready", CoachReadyScreen(model: .ready(ready))),
      watch("ready-warnings", CoachReadyScreen(model: .ready(ReadyInfo(
        sessionName: "Full sim", targetText: "1:20:00", athleteChip: "A1 \u{00B7} L",
        chips: ["No headphones: cues by vibration", "Heart rate off. The coach still works."],
        batteryLine: "Battery 54%. A full sim needs about 60%.")))),
      watch("run", CoachStepScreen(model: run, onMissed: {})),
      watch("run-over", CoachStepScreen(model: over, onMissed: {})),
      watch("run-transition", CoachStepScreen(model: { var m = run; m.badge = "Transition"; m.dominant = "0:12"; m.deltaSeconds = -14; m.next = "Next: Sled push"; return m }(), onMissed: {})),
      watch("station-time", CoachStepScreen(model: station, onMissed: {})),
      watch("station-time-sled", CoachStepScreen(model: sled, onMissed: {})),
      watch("station-reps", CoachStepScreen(model: walls, onMissed: {})),
      watch("station-reps-low-confidence", CoachStepScreen(model: lowConf, onMissed: {})),
      watch("toast-headphones", CoachStepScreen(model: { var m = station; m.toast = "Headphones lost, vibrating instead"; return m }(), onMissed: {})),
      watch("alarm-workout-lost", CoachStepScreen(model: { var m = run; m.alarm = "Workout session ended"; return m }(), onMissed: {})),
      watch("menu", CoachMenuScreen()),
      watch("finish-undo-window", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:18:42", line: "1:18 under target", early: false, best: "Row \u{2212}0:25", worst: "Sled pull +0:41",
        undoSecondsLeft: 8, totalSeconds: 4722, stations: allStations), animate: false)),
      watch("finish-saving", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:18:42", line: "1:18 under target", early: false, best: "Row \u{2212}0:25", worst: "Sled pull +0:41",
        saving: true, totalSeconds: 4722, stations: allStations), animate: false)),
      watch("finish-under", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:18:42", line: "1:18 under target", early: false, best: "Row \u{2212}0:25", worst: "Sled pull +0:41",
        totalSeconds: 4722, stations: allStations), animate: false)),
      watch("finish-over", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "1:22:10", line: "2:10 over target", early: false, best: "Row \u{2212}0:25", worst: "Sled pull +0:41",
        totalSeconds: 4930, stations: allStations), animate: false)),
      watch("finish-early", CoachFinishScreen(model: FinishScreenModel(
        mode: .saved, totalText: "52:10", line: "Ended at Row. 5 of 8 stations.", early: true,
        totalSeconds: 3130, stations: earlyStations), animate: false)),
      watch("finish-save-failed", CoachFinishScreen(model: FinishScreenModel(
        mode: .saveFailed(missing: 1), totalText: "1:18:42", line: "1:18 under target", early: false,
        totalSeconds: 4722, stations: allStations), animate: false)),
    ]
  }

  public static var phoneScreens: [CatalogEntry] {
    let full = SampleData.result(extra: [4: 45, 5: 41, 13: 18])
    let partial = SampleData.result(extra: [4: 30], until: 10)
    return [
      phone("setup-first-launch", SetupScreen(model: SetupModel()).frame(width: Theme.phone.width)),
      phone("setup-sending", SetupScreen(model: SetupModel(send: .sending(watchName: "Apple Watch"))).frame(width: Theme.phone.width)),
      phone("setup-sent", SetupScreen(model: SetupModel(division: .proWomen, targetSeconds: 4500, type: .halfSim, send: .sent)).frame(width: Theme.phone.width)),
      phone("setup-watch-app-missing", SetupScreen(model: SetupModel(send: .watchAppMissing)).frame(width: Theme.phone.width)),
      phone("setup-send-failed", SetupScreen(model: SetupModel(send: .failed)).frame(width: Theme.phone.width)),
      phone("summary-empty", SummaryScreen(state: .empty).frame(width: Theme.phone.width, height: 300)),
      phone("summary-syncing", SummaryScreen(state: .syncing(percent: 42)).frame(width: Theme.phone.width, height: 300)),
      phone("summary-sync-failed", SummaryScreen(state: .failed).frame(width: Theme.phone.width, height: 300)),
      phone("summary-full", SummaryScreen(state: .ready(full)).frame(width: Theme.phone.width)),
      phone("summary-partial", SummaryScreen(state: .ready(partial)).frame(width: Theme.phone.width)),
      phone("summary-share-error", SummaryScreen(state: .ready(full), shareError: true).frame(width: Theme.phone.width)),
      phone("sharecard-full", ShareCardView(result: full)),
      phone("sharecard-partial", ShareCardView(result: partial)),
    ]
  }

  public static var all: [CatalogEntry] { watchScreens + phoneScreens }
}
