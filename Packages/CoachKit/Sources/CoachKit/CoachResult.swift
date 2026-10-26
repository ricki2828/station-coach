import Foundation

/// One wall-ball set as it happened.
public struct WallBallSet: Equatable {
  public let reps: Int
  public let startMs: Int64
  public let endMs: Int64
  /// Seconds between the previous set's last rep and this set's first rep; 0 for the first set.
  public let restBeforeSeconds: Int
}

public enum WallBallAnalysis {
  /// A set ends where the gap to the next rep is longer than `restGapSeconds`: sets are what the athlete did,
  /// not the plan's sizes, so a set of 12 stays 12 and its rest is measured.
  public static func sets(repTimesMs: [Int64], restGapSeconds: Int = 8) -> [WallBallSet] {
    var out: [WallBallSet] = []
    var start = 0
    for i in 1...max(repTimesMs.count, 1) where !repTimesMs.isEmpty {
      guard i == repTimesMs.count || repTimesMs[i] - repTimesMs[i - 1] > Int64(restGapSeconds) * 1000 else { continue }
      let slice = repTimesMs[start..<i]
      let rest = out.last.map { Int((slice.first! - $0.endMs) / 1000) } ?? 0
      out.append(WallBallSet(reps: slice.count, startMs: slice.first!, endMs: slice.last!, restBeforeSeconds: max(0, rest)))
      start = i
    }
    return out
  }

  public static func totalRestSeconds(_ sets: [WallBallSet]) -> Int { sets.reduce(0) { $0 + $1.restBeforeSeconds } }
}

/// Everything the phone needs to summarise a coached session; written by the watch as `coach.json`.
public struct CoachResult: Codable, Equatable {
  public var plan: SessionPlan
  public var splits: [StepSplit]
  public var early: Bool
  /// Epoch ms of each counted wall-ball rep (the heuristic's view, before corrections).
  public var repTimesMs: [Int64]
  /// Net manual +/- the athlete applied to the count.
  public var repCorrection: Int
  public var startedAtEpochMs: Int64
  public var endedAtEpochMs: Int64

  public init(plan: SessionPlan, splits: [StepSplit], early: Bool, repTimesMs: [Int64], repCorrection: Int, startedAtEpochMs: Int64, endedAtEpochMs: Int64) {
    self.plan = plan
    self.splits = splits
    self.early = early
    self.repTimesMs = repTimesMs
    self.repCorrection = repCorrection
    self.startedAtEpochMs = startedAtEpochMs
    self.endedAtEpochMs = endedAtEpochMs
  }

  public static let fileName = "coach.json"

  public struct Row: Equatable {
    public let step: PlanStep
    /// nil when the step was not completed. Never 0:00.
    public let actualSeconds: Int?
    public var deltaSeconds: Int? { actualSeconds.map { $0 - step.targetSeconds } }
  }

  public var rows: [Row] {
    plan.steps.map { step in
      let s = splits.first { $0.stepIndex == step.index }
      let actual = s?.endMs.map { Int(($0 - s!.startMs) / 1000) }
      return Row(step: step, actualSeconds: actual)
    }
  }

  public var totalSeconds: Int { Int((endedAtEpochMs - startedAtEpochMs) / 1000) }
  public var completedStationCount: Int { rows.filter { !$0.step.isRun && $0.actualSeconds != nil }.count }

  /// Net deviation of completed steps from plan (positive = over).
  public var deltaSeconds: Int { rows.compactMap(\.deltaSeconds).reduce(0, +) }

  public func wallBallSets() -> [WallBallSet] {
    // First wall-ball step that was started; only reps inside its window count (a focus session has three).
    guard let step = plan.steps.first(where: { s in s.activity == .wallBalls && splits.contains { $0.stepIndex == s.index } }),
          let split = splits.first(where: { $0.stepIndex == step.index }) else { return [] }
    let end = split.endMs ?? endedAtEpochMs
    let reps = repTimesMs.filter { $0 >= split.startMs && $0 <= end }
    return WallBallAnalysis.sets(repTimesMs: reps)
  }

  /// Best and worst completed station against plan, as (name, delta).
  public var bestWorstStations: (best: (String, Int)?, worst: (String, Int)?) {
    let st = rows.filter { !$0.step.isRun }.compactMap { r in r.deltaSeconds.map { (r.step.name, $0) } }
    return (st.min { $0.1 < $1.1 }, st.max { $0.1 < $1.1 })
  }

  public var shortTitle: String {
    early ? "\(plan.title), \(completedStationCount) of \(plan.stationCount) stations" : plan.title
  }
}

public struct Insight: Equatable {
  public let rule: Int
  public let headline: String
}

/// The summary's one headline. The first rule that fires wins:
/// 1. the biggest run slowdown against run 1 (changeover time taken out of runs 2 and later);
/// 2. the station furthest over plan;
/// 3. wall-ball rest as a share of the station;
/// else a plain total against target.
public enum InsightPicker {
  public static let runSlowdownMin = 20
  public static let stationOverMin = 15
  public static let restShareMin = 0.25
  public static let restSecondsMin = 30

  public static func pick(_ result: CoachResult) -> Insight {
    let rows = result.rows
    // 1. Run slowdown vs run 1, named by the station before it.
    var worst: RunFade.Slowdown?
    for s in RunFade.slowdowns(result) where s.seconds >= runSlowdownMin && s.seconds > (worst?.seconds ?? 0) { worst = s }
    if let worst { return Insight(rule: 1, headline: "Your run after the \(worst.after.lowercased()) was \(worst.seconds)\u{00A0}s slower than run 1") }
    // 2. Station furthest over plan.
    let over = rows.filter { !$0.step.isRun }.compactMap { r in r.deltaSeconds.map { (r.step.name, $0) } }.max { $0.1 < $1.1 }
    if let over, over.1 >= stationOverMin {
      return Insight(rule: 2, headline: "\(over.0) was \(Fmt.gap(over.1)) over plan")
    }
    // 3. Wall-ball rest.
    if let wb = rows.first(where: { $0.step.activity == .wallBalls }), let dur = wb.actualSeconds, dur > 0 {
      let rest = WallBallAnalysis.totalRestSeconds(result.wallBallSets())
      let share = Double(rest) / Double(dur)
      if rest >= restSecondsMin, share >= restShareMin {
        return Insight(rule: 3, headline: "You rested \(Fmt.gap(rest)) in wall balls, \(Int((share * 100).rounded()))% of the station")
      }
    }
    let planned = result.plan.plannedSeconds
    return Insight(rule: 0, headline: "\(Fmt.clock(result.totalSeconds)) against a \(Fmt.clock(planned)) plan")
  }
}
