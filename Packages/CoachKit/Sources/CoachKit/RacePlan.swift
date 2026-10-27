import Foundation

/// One line of the race-day split table: a run or a station, with its target split.
public struct RaceSegment: Equatable, Identifiable {
  public let id: Int
  public let name: String
  public let targetSeconds: Int
  public let isRun: Bool
  public let activity: Activity
}

/// The race-day plan: the same division targets as a full sim, shown as per-segment splits. The shares are typical
/// defaults, so every split is an estimate; the phone says so.
public enum RacePlan {
  /// 16 segments in race order. Changeovers are folded into the runs (about `changeoverSeconds` each, at both ends).
  public static func segments(_ plan: SessionPlan) -> [RaceSegment] {
    plan.steps.map { RaceSegment(id: $0.index, name: $0.name, targetSeconds: $0.targetSeconds, isRun: $0.isRun, activity: $0.activity) }
  }

  /// "Run 3 . 5:24" / "Sled pull . 4:25"
  public static func line(_ s: RaceSegment) -> String { "\(s.name) \u{00B7} \(Fmt.clock(s.targetSeconds))" }

  /// The changeover allowance inside each run split, for the footnote.
  public static func changeoverSeconds(_ plan: SessionPlan) -> Int { plan.transitionSeconds }

  public static func footnote(_ plan: SessionPlan) -> String {
    "Runs include changeovers (about \(Fmt.clock(changeoverSeconds(plan))) each)."
  }

  public static let estimateNote = "From your target with typical shares. Edit later in v2."
}
