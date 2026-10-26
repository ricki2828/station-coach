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

/// One NO REP tap during a wall-ball rest: the athlete's throw did not count and was added back to reps left.
public struct NoRepEvent: Codable, Equatable {
  public let tMs: Int64
  /// 0-based wall-ball set the rep belonged to.
  public let setIndex: Int
  /// Plan step the tap happened in. Nil in files from before this field: the first wall-ball step.
  public let stepIndex: Int?

  public init(tMs: Int64, setIndex: Int, stepIndex: Int? = nil) {
    self.tMs = tMs
    self.setIndex = setIndex
    self.stepIndex = stepIndex
  }
}

/// What the phone's Edit count sheet sets: the final counts for the wall balls, replacing the watch's.
public struct WallBallCorrection: Codable, Equatable {
  public var validReps: Int
  public var noReps: Int

  public init(validReps: Int, noReps: Int) {
    self.validReps = validReps
    self.noReps = noReps
  }

  public static let maxValidReps = 300
  public static let maxNoReps = 100

  /// Within what the sheet can sensibly mean: 0...300 valid, 0...100 no-reps.
  public var clamped: WallBallCorrection {
    WallBallCorrection(validReps: min(max(0, validReps), Self.maxValidReps), noReps: min(max(0, noReps), Self.maxNoReps))
  }
}

/// Where a running rep count sits in the plan's sets.
public enum WallBallProgress {
  /// The 0-based set that rep number `repsDone` (the last valid one) belongs to; 0 before any rep, the last set past the end.
  public static func setIndex(repsDone: Int, sets: [Int]) -> Int {
    guard !sets.isEmpty else { return 0 }
    var cumulative = 0
    for (k, size) in sets.enumerated() {
      cumulative += size
      if repsDone <= cumulative { return k }
    }
    return sets.count - 1
  }
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
  /// Every NO REP tap, in order. Absent in files written before the feature.
  public var noReps: [NoRepEvent]
  /// Counts as corrected afterwards on the phone; nil = the watch's data stands.
  public var wallBallCorrection: WallBallCorrection?

  public init(plan: SessionPlan, splits: [StepSplit], early: Bool, repTimesMs: [Int64], repCorrection: Int, startedAtEpochMs: Int64, endedAtEpochMs: Int64,
              noReps: [NoRepEvent] = [], wallBallCorrection: WallBallCorrection? = nil) {
    self.noReps = noReps
    self.wallBallCorrection = wallBallCorrection
    self.plan = plan
    self.splits = splits
    self.early = early
    self.repTimesMs = repTimesMs
    self.repCorrection = repCorrection
    self.startedAtEpochMs = startedAtEpochMs
    self.endedAtEpochMs = endedAtEpochMs
  }

  private enum CodingKeys: String, CodingKey {
    case plan, splits, early, repTimesMs, repCorrection, startedAtEpochMs, endedAtEpochMs, noReps, wallBallCorrection
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    plan = try c.decode(SessionPlan.self, forKey: .plan)
    splits = try c.decode([StepSplit].self, forKey: .splits)
    early = try c.decode(Bool.self, forKey: .early)
    repTimesMs = try c.decode([Int64].self, forKey: .repTimesMs)
    repCorrection = try c.decode(Int.self, forKey: .repCorrection)
    startedAtEpochMs = try c.decode(Int64.self, forKey: .startedAtEpochMs)
    endedAtEpochMs = try c.decode(Int64.self, forKey: .endedAtEpochMs)
    noReps = try c.decodeIfPresent([NoRepEvent].self, forKey: .noReps) ?? []
    if let corr = try? c.decodeIfPresent(WallBallCorrection.self, forKey: .wallBallCorrection) {
      wallBallCorrection = corr
    } else if let total = try? c.decodeIfPresent(Int.self, forKey: .wallBallCorrection) {
      // Early builds stored the corrected total of throws; the no-reps were the logged taps.
      wallBallCorrection = WallBallCorrection(validReps: max(0, total - noReps.count), noReps: noReps.count)
    } else {
      wallBallCorrection = nil
    }
  }

  public static let fileName = "coach.json"

  /// Phone-only file next to `coach.json`. The watch never sends it, so a re-sent `coach.json` cannot overwrite a correction.
  public static let correctionFileName = "phone-correction.json"

  /// The watch's `coach.json` with the phone's sidecar correction (if any) applied.
  public static func load(inSessionFolder folder: URL) throws -> CoachResult {
    var result = try JSONDecoder().decode(CoachResult.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    if let data = try? Data(contentsOf: folder.appendingPathComponent(correctionFileName)),
       let c = try? JSONDecoder().decode(WallBallCorrection.self, from: data) {
      result.wallBallCorrection = c.clamped
    }
    return result
  }

  /// Writes the phone's correction to the sidecar only; `coach.json` is never touched. Returns the result with it applied.
  @discardableResult
  public static func saveCorrection(_ correction: WallBallCorrection, inSessionFolder folder: URL) throws -> CoachResult {
    _ = try JSONDecoder().decode(CoachResult.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    try JSONEncoder().encode(correction.clamped).write(to: folder.appendingPathComponent(correctionFileName), options: .atomic)
    return try load(inSessionFolder: folder)
  }

  /// No-reps: the phone's correction when set, else the taps logged on the watch.
  public var noRepCount: Int { max(0, wallBallCorrection?.noReps ?? noReps.count) }

  /// Throws that counted: the phone's correction when set, else the watch's count (plus manual +/-) minus the no-reps.
  public var validReps: Int {
    max(0, wallBallCorrection?.validReps ?? (repTimesMs.count + repCorrection - noReps.count))
  }

  /// Every throw, no-reps included.
  public var totalThrows: Int { validReps + noRepCount }

  /// Index of the first wall-ball step, where events without a `stepIndex` belong.
  private var firstWallBallStep: Int? { plan.steps.first { $0.activity == .wallBalls }?.index }

  /// Taps in one wall-ball step.
  public func noReps(inStep step: Int) -> [NoRepEvent] {
    noReps.filter { ($0.stepIndex ?? firstWallBallStep) == step }
  }

  /// No-reps per set of one wall-ball step (default: the first), sized to that step's sets. From the logged taps.
  public func noRepsBySet(step: Int? = nil) -> [Int] {
    let index = step ?? firstWallBallStep
    let events = index.map(noReps(inStep:)) ?? []
    let planned = index.map { plan.steps[$0].sets.count } ?? 0
    var out = [Int](repeating: 0, count: max(planned, (events.map(\.setIndex).max() ?? -1) + 1))
    for e in events where e.setIndex >= 0 { out[e.setIndex] += 1 }
    return out
  }

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
/// 4. no-reps that came late in the wall balls;
/// else a plain total against target.
public enum InsightPicker {
  public static let runSlowdownMin = 20
  public static let stationOverMin = 15
  public static let restShareMin = 0.25
  public static let restSecondsMin = 30
  public static let lateNoRepsMin = 3

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
    // 4. No-reps that clustered in the last third of one wall-ball step's sets. Only when the taps are the whole story:
    // a phone correction that changed the count makes the per-set split unreliable.
    if result.noRepCount >= lateNoRepsMin, result.noRepCount == result.noReps.count {
      for step in result.plan.steps where step.activity == .wallBalls && step.sets.count >= 3 {
        let events = result.noReps(inStep: step.index)
        let firstLate = (step.sets.count * 2 + 2) / 3 // ceil(2n/3): the first set of the last third
        let late = events.filter { $0.setIndex >= firstLate }
        if late.count >= lateNoRepsMin, late.count * 3 >= events.count * 2 {
          return Insight(rule: 4, headline: "Your no-reps came late: \(late.count) after set \(firstLate). Depth fades when you tire.")
        }
      }
    }
    let planned = result.plan.plannedSeconds
    return Insight(rule: 0, headline: "\(Fmt.clock(result.totalSeconds)) against a \(Fmt.clock(planned)) plan")
  }
}
