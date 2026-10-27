import Foundation

/// The coach's lines. Number first, no filler. Cue wording follows the coaching content; nothing here
/// claims a live measurement (no live pace, no stroke rate): targets come from the plan.
public enum CoachCopy {
  /// Stations that leave the legs heavy for the run that follows.
  public static let heavyLegs: Set<Activity> = [.sledPush, .sledPull, .burpeeBroadJump, .sandbagLunges]

  public static let jogIn = "Jog in."

  /// Said once during a run's last `transitionSeconds` (the walk-in allowance at its end), when a station follows
  /// and has a target to jog towards. A cue of its own at the lowest priority, so the gap rules decide when.
  public static func jogInDue(run: PlanStep, next: PlanStep?, elapsedSeconds: Int, transitionSeconds: Int) -> Bool {
    guard run.isRun, let next, !next.isRun, next.targetSeconds > 0, transitionSeconds > 0 else { return false }
    return elapsedSeconds >= max(0, run.targetSeconds - transitionSeconds)
  }

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

  /// Spoken on the first NO REP tap only.
  public static let noRepNoted = "No rep noted."

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

  /// Said once at START. Number first, one short line. The first session sets the baseline; later ones go out steady.
  public static func sessionStart(plan: SessionPlan, isFirst: Bool) -> String {
    let target = Fmt.clock(plan.plannedSeconds)
    return isFirst ? "\(target) target. Start easy, run 1 sets your baseline." : "\(target) target. Hold run 1 back."
  }

  /// One line after the numbers, chosen by outcome: ended early, first session, under, over, on target.
  /// Reads the result only; no live-measurement or "AI" claims.
  public static func finishPersonality(totalSeconds: Int, plannedSeconds: Int, isFirst: Bool, early: Bool) -> String {
    if early { return "Ended early. Everything up to here is saved." }
    if isFirst { return "First session logged. This time is your baseline." }
    let d = totalSeconds - plannedSeconds
    if d == 0 { return "On target. Exactly the plan." }
    return d < 0 ? "\(Fmt.gap(d)) under target. Hold that next time." : "\(Fmt.gap(d)) over target. Start with your slowest station."
  }

  /// The History tag for a session that did not run start to finish. A recovered session (resumed after the app stopped,
  /// or closed from a checkpoint) wins over "Ended early". Nil for a normal finish.
  public static func sessionLabel(early: Bool, recovered: Bool) -> String? {
    if recovered { return "Recovered" }
    return early ? "Ended early" : nil
  }
}
