import Foundation

/// The coach's lines. Number first, no filler. Cue wording follows the coaching content; nothing here
/// claims a live measurement (no live pace, no stroke rate): targets come from the plan.
public enum CoachCopy {
  /// Stations that leave the legs heavy for the run that follows.
  public static let heavyLegs: Set<Activity> = [.sledPush, .sledPull, .burpeeBroadJump, .sandbagLunges]

  public static func stationIntro(_ step: PlanStep) -> String {
    let name = Stations.name(step.activity)
    switch step.activity {
    case .skierg: return "\(name). 1,000 metres. Hinge from the hips."
    case .sledPush: return "\(name). Four lengths. Hips low, short strides."
    case .sledPull: return "\(name). Four lengths. Legs and back, not arms."
    case .burpeeBroadJump: return "\(name). 80 metres. Steady rhythm, small jumps."
    case .row: return "\(name). 1,000 metres. Even splits, don't sprint."
    case .farmersCarry: return "\(name). 200 metres. Don't put them down."
    case .sandbagLunges: return "\(name). 100 metres. One every 2 seconds."
    case .wallBalls:
      let reps = step.reps ?? 100
      let setSize = step.sets.first ?? 15
      return "\(name). \(reps) reps. Sets of \(setSize), \(setSize >= 15 ? "five" : "four") breaths between."
    default: return name
    }
  }

  /// Said once, halfway through a station's target time. Nil for wall balls (set cues instead).
  public static func midStation(_ step: PlanStep) -> String? {
    switch step.activity {
    case .skierg: return "Hold \(Fmt.clock(step.targetSeconds / 2)) per 500. Build the last 200."
    case .sledPush: return "Short fast steps. Don't stop. 2 lengths left."
    case .sledPull: return "Sit back, drive with the legs. 2 lengths left."
    case .burpeeBroadJump: return "One every 5 seconds. Keep the rhythm, don't chase distance."
    case .row: return "Hold \(Fmt.clock(step.targetSeconds / 2)) per 500. This is not a rest."
    case .farmersCarry: return "Quick steps. Don't put them down. 100 to go."
    case .sandbagLunges: return "One lunge every 2 seconds. Knee down. 50 metres left."
    default: return nil
    }
  }

  /// "30 seconds up on plan." (ahead) / "20 seconds down, stay calm." (behind) / "On plan."
  public static func planCheck(deltaSeconds: Int) -> String {
    let b = DeltaMath.spokenBucket(deltaSeconds)
    if b == 0 { return "On plan." }
    let line = b < 0 ? "\(Fmt.spoken(-b)) up on plan." : "\(Fmt.spoken(b)) down, stay calm."
    return line.prefix(1).uppercased() + line.dropFirst()
  }

  /// Said as a run begins. After a heavy station it carries the legs line; after any station a plan check.
  /// The spoken target is the kilometre alone: the plan's run target also holds two changeover allowances.
  public static func runStart(run: PlanStep, after station: PlanStep?, deltaSeconds: Int, transitionSeconds: Int = 0) -> String {
    var parts: [String] = []
    if station != nil { parts.append(planCheck(deltaSeconds: deltaSeconds)) }
    if let station, heavyLegs.contains(station.activity) {
      parts.append("Legs feel heavy for 200 metres. Short quick steps.")
    }
    parts.append("Target \(Fmt.clock(max(0, run.targetSeconds - 2 * transitionSeconds))) for this kilometre.")
    return parts.joined(separator: " ")
  }

  public static func wallBallSetDone(nextSet: Int?) -> String {
    guard let n = nextSet else { return "Set done. Last one done. Breathe." }
    return "Set done. Breathe. Next \(Fmt.word(n))."
  }

  /// "1:18:42. 1:18 under target. Best: Row, 0:25 under. Worst: Sled pull, 0:41 over."
  public static func finish(totalSeconds: Int, plannedSeconds: Int, best: (String, Int)?, worst: (String, Int)?, early: Bool) -> String {
    let d = totalSeconds - plannedSeconds
    var s = "\(Fmt.clock(totalSeconds))."
    if !early { s += d == 0 ? " On target." : " \(Fmt.gap(d)) \(d < 0 ? "under" : "over") target." }
    if let best, best.1 < 0 { s += " Best: \(best.0), \(Fmt.gap(best.1)) under." }
    if let worst, worst.1 > 0 { s += " Worst: \(worst.0), \(Fmt.gap(worst.1)) over." }
    return s
  }
}
