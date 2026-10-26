import Foundation

public enum Division: String, CaseIterable, Codable, Identifiable {
  case openMen = "open_men", openWomen = "open_women", proMen = "pro_men", proWomen = "pro_women"
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .openMen: return "Open men"
    case .openWomen: return "Open women"
    case .proMen: return "Pro men"
    case .proWomen: return "Pro women"
    }
  }
}

public enum SessionType: String, CaseIterable, Codable, Identifiable {
  case fullSim = "full_sim", halfSim = "half_sim", wallBallFocus = "wall_ball_focus"
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .fullSim: return "Full sim"
    case .halfSim: return "Half sim"
    case .wallBallFocus: return "Wall-ball focus"
    }
  }
  public var detail: String {
    switch self {
    case .fullSim: return "8 runs, 8 stations"
    case .halfSim: return "Runs 1-4, stations 1-4"
    case .wallBallFocus: return "1 km run, 50 wall balls, x3"
    }
  }
}

/// What a station asks for, in race order. Names are what the screen and the cues say.
public enum Stations {
  public static let race: [Activity] = [.skierg, .sledPush, .sledPull, .burpeeBroadJump, .row, .farmersCarry, .sandbagLunges, .wallBalls]

  public static func name(_ a: Activity) -> String {
    switch a {
    case .run: return "Run"
    case .transition: return "Transition"
    case .skierg: return "SkiErg"
    case .sledPush: return "Sled push"
    case .sledPull: return "Sled pull"
    case .burpeeBroadJump: return "Burpee broad jumps"
    case .row: return "Row"
    case .farmersCarry: return "Farmers carry"
    case .sandbagLunges: return "Sandbag lunges"
    case .wallBalls: return "Wall balls"
    case .rest: return "Rest"
    }
  }

  /// "1,000 m", "100 reps".
  public static func quantity(_ a: Activity, reps: Int? = nil) -> String {
    switch a {
    case .skierg, .row: return "1,000 m"
    case .sledPush, .sledPull: return "50 m"
    case .burpeeBroadJump: return "80 m"
    case .farmersCarry: return "200 m"
    case .sandbagLunges: return "100 m"
    case .wallBalls: return "\(reps ?? 100) reps"
    default: return ""
    }
  }

  /// Wall-ball sets: 100 reps are 15 x 6 then 10; shorter rounds use sets of 10.
  public static func wallBallSets(reps: Int) -> [Int] {
    if reps == 100 { return [15, 15, 15, 15, 15, 15, 10] }
    var sets = Array(repeating: 10, count: reps / 10)
    if reps % 10 > 0 { sets.append(reps % 10) }
    return sets
  }
}

public struct PlanStep: Codable, Equatable {
  /// `.run` or a station activity.
  public let activity: Activity
  public let index: Int
  /// 1-based run number for runs.
  public let runNumber: Int?
  public let targetSeconds: Int
  public let reps: Int?
  public let sets: [Int]

  public var isRun: Bool { activity == .run }
  public var name: String { isRun ? "Run \(runNumber ?? 0)" : Stations.name(activity) }
}

public struct SessionPlan: Codable, Equatable {
  public let division: Division
  public let type: SessionType
  /// The race target the athlete typed (full race), before the session type scales it.
  public let raceTargetSeconds: Int
  public let steps: [PlanStep]
  /// Seconds at the start of a run after a station that count as transition, not running.
  public let transitionSeconds: Int

  public var plannedSeconds: Int { steps.reduce(0) { $0 + $1.targetSeconds } }
  public var stationCount: Int { steps.filter { !$0.isRun }.count }
  public var title: String { type.title }
}

/// Builds a plan from a division, a race target and a session type.
/// The split is a fixed default profile (an estimate, not editable in v1): runs 48% of the target,
/// stations 46%, transitions 6%. Station shares are of the station 46%.
public enum PlanBuilder {
  public static let runShare = 0.48
  public static let stationShare = 0.46
  public static let transitionShare = 0.06
  public static let changeovers = 16.0

  /// Percent of the station total, in race order; sums to 100.
  public static let stationProfile: [Activity: Int] = [
    .skierg: 12, .sledPush: 9, .sledPull: 12, .burpeeBroadJump: 14,
    .row: 13, .farmersCarry: 8, .sandbagLunges: 14, .wallBalls: 18,
  ]

  public static let minTarget = 30 * 60
  public static let maxTarget = 3 * 3600

  public static func clamped(_ target: Int) -> Int { min(max(target, minTarget), maxTarget) }

  public static func build(division: Division, target: Int, type: SessionType) -> SessionPlan {
    let t = Double(clamped(target))
    let perRun = t * runShare / 8
    let perRunTransition = t * transitionShare / 8
    let runTarget = Int((perRun + perRunTransition).rounded())
    func stationTarget(_ a: Activity, scale: Double = 1) -> Int {
      Int((t * stationShare * Double(stationProfile[a] ?? 0) / 100 * scale).rounded())
    }
    var steps: [PlanStep] = []
    func add(_ step: (Int) -> PlanStep) { steps.append(step(steps.count)) }
    switch type {
    case .fullSim, .halfSim:
      let n = type == .fullSim ? 8 : 4
      for i in 0..<n {
        add { PlanStep(activity: .run, index: $0, runNumber: i + 1, targetSeconds: runTarget, reps: nil, sets: []) }
        let a = Stations.race[i]
        let reps: Int? = a == .wallBalls ? 100 : nil
        add { PlanStep(activity: a, index: $0, runNumber: nil, targetSeconds: stationTarget(a), reps: reps, sets: reps.map(Stations.wallBallSets) ?? []) }
      }
    case .wallBallFocus:
      for i in 0..<3 {
        add { PlanStep(activity: .run, index: $0, runNumber: i + 1, targetSeconds: runTarget, reps: nil, sets: []) }
        add { PlanStep(activity: .wallBalls, index: $0, runNumber: nil, targetSeconds: stationTarget(.wallBalls, scale: 0.5), reps: 50, sets: Stations.wallBallSets(reps: 50)) }
      }
    }
    // Rounding leaves a few seconds; the last step of a full sim absorbs them so the plan adds up to the target.
    if type == .fullSim, let last = steps.last {
      let diff = clamped(target) - steps.reduce(0) { $0 + $1.targetSeconds }
      steps[steps.count - 1] = PlanStep(activity: last.activity, index: last.index, runNumber: last.runNumber,
                                        targetSeconds: last.targetSeconds + diff, reps: last.reps, sets: last.sets)
    }
    return SessionPlan(division: division, type: type, raceTargetSeconds: clamped(target), steps: steps,
                       transitionSeconds: Int((t * transitionShare / changeovers).rounded()))
  }
}
