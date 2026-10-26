import CoachKit
import SwiftUI

/// Synthetic session history for the Home and History screens.
public enum HistorySamples {
  /// Sat 24 Oct 2026, 10:00 UTC.
  public static let sat24Oct: Int64 = 1_792_836_000
  /// Mon 26 Oct 2026, noon UTC.
  public static let today = Date(timeIntervalSince1970: 1_793_016_000)
  public static let day: Int64 = 86_400

  /// A finished (or `until`-cut) session whose run fade is exactly `fade`; `stationExtra` adds seconds to stations.
  public static func record(_ id: String, type: SessionType, startDay: Int64, fade: Int, stationExtra: [Activity: Int] = [:],
                            until: Int? = nil, rest: Int = 10) -> SessionRecord {
    let plan = PlanBuilder.build(division: .openMen, target: 5400, type: type)
    let pattern = [-6, 12, 0, 4, -4, -2, -4]
    func build(shift: Int) -> CoachResult {
      var t: Int64 = 0
      var splits: [StepSplit] = []
      for step in plan.steps {
        if let until, step.index >= until { break }
        var extra = stationExtra[step.activity] ?? 0
        if step.isRun, let n = step.runNumber, n > 1 { extra += pattern[(n - 2) % pattern.count] + shift }
        let d = Int64(max(30, step.targetSeconds + extra)) * 1000
        splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
        t += d
      }
      var reps: [Int64] = []
      if let wb = plan.steps.first(where: { $0.activity == .wallBalls }), let s = splits.first(where: { $0.stepIndex == wb.index }) {
        var r = s.startMs + 1_000
        for size in wb.sets { for _ in 0..<size { reps.append(r); r += 2_000 }; r += Int64(rest - 2) * 1000 }
      }
      let start = (sat24Oct + startDay * day) * 1000
      return CoachResult(plan: plan, splits: splits, early: until != nil, repTimesMs: reps, repCorrection: 0,
                         startedAtEpochMs: start, endedAtEpochMs: start + t)
    }
    let first = build(shift: 0)
    let shift = fade - (RunFade.fade(first) ?? fade)
    return SessionRecord(id: id, result: build(shift: shift))
  }

  public static let baseline = [record("s1", type: .fullSim, startDay: 0, fade: 27, stationExtra: [.sledPush: 50, .skierg: 20])]
  public static let trend: [SessionRecord] = [
    record("t1", type: .halfSim, startDay: -14, fade: 15, stationExtra: [.sledPush: 20]),
    record("t2", type: .halfSim, startDay: -7, fade: 12, stationExtra: [.sledPush: 20]),
    record("t3", type: .fullSim, startDay: 0, fade: 27, stationExtra: [.sledPush: 50, .skierg: 20]),
  ]
  public static func trend(latestFade: Int) -> [SessionRecord] {
    trend + [record("t4", type: .fullSim, startDay: 1, fade: latestFade, stationExtra: [.sledPush: 20, .row: -15])]
  }

  /// Last session had a wall-ball problem: big rest, wall balls the worst station.
  public static let wallBalls = [record("w1", type: .fullSim, startDay: 1, fade: 18, stationExtra: [.wallBalls: 70], rest: 26)]

  public static let list: [SessionRecord] = [
    record("h1", type: .fullSim, startDay: 1, fade: 19, stationExtra: [.sledPush: 20, .row: -15]),
    record("h2", type: .halfSim, startDay: -3, fade: 14, stationExtra: [.skierg: -30, .row: -20]),
    record("h3", type: .wallBallFocus, startDay: -6, fade: 12, stationExtra: [.wallBalls: 15]),
    record("h4", type: .fullSim, startDay: -9, fade: 31, stationExtra: [.sledPush: 40], until: 11),
  ]
}

extension ScreenCatalog {
  private static func phoneW(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view.frame(width: Theme.phone.width)))
  }

  static func homeModel(_ records: [SessionRecord]) -> HomeModel {
    HomeModel(records: records, setup: RaceSetup(), now: HistorySamples.today)
  }

  public static var homeStates: [(name: String, model: HomeModel)] {
    [
      ("none", homeModel([])),
      ("baseline", homeModel(HistorySamples.baseline)),
      ("trend-down", homeModel(HistorySamples.trend(latestFade: 19))),
      ("trend-steady", homeModel(HistorySamples.trend(latestFade: 28))),
      ("trend-up", homeModel(HistorySamples.trend(latestFade: 31))),
      ("next-wallballs", homeModel(HistorySamples.wallBalls)),
    ]
  }

  public static var homeScreens: [CatalogEntry] {
    let list = HistorySamples.list
    let detailFull = list[0]
    let detailPartial = list[3]
    return homeStates.map { phoneW("home-\($0.name)", HomeScreen(model: $0.model, today: HistorySamples.today)) } + [
      phoneW("history-empty", HistoryScreen(records: [])),
      phoneW("history-list", HistoryScreen(records: list)),
      phoneW("history-syncing", HistoryScreen(records: Array(list.prefix(2)), syncPercent: 42)),
      phoneW("detail-full", SessionDetailScreen(record: detailFull)),
      phoneW("detail-partial", SessionDetailScreen(record: detailPartial)),
      phoneW("detail-no-reps", SessionDetailScreen(record: detailFull, noReps: 3, onSaveCount: { _ in })),
      phoneW("detail-edit-count", WallBallEditSheet(initial: WallBallEdit(validReps: 97, noReps: 3))),
    ]
  }
}
