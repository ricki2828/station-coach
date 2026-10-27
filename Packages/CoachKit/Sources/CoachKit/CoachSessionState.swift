import Foundation

/// The pure state of a coached session: everything the watch must remember to carry on after a relaunch. The
/// live wall-ball detector (a signal filter) is not part of it; its rep times are banked here instead.
public struct CoachSessionState: Codable, Equatable {
  public var machine: SessionMachine
  /// Epoch ms of the counted wall-ball reps per plan step. Steps left are final; the step in progress holds the
  /// latest checkpointed times.
  public var repsByStep: [Int: [Int64]] = [:]
  public var correctionByStep: [Int: Int] = [:]
  /// Net manual +/- in the wall-ball step in progress.
  public var repCorrection = 0
  public var noRepLog = NoRepLog()
  public var announcedSets = Set<Int>()
  public var enteredWallBalls = Set<Int>()
  public var midCueDone = Set<Int>()
  public var jogInDone = Set<Int>()
  public var noRepAnnounced = false

  public init(plan: SessionPlan) { machine = SessionMachine(plan: plan) }

  public init(machine: SessionMachine) { self.machine = machine }

  /// Valid reps left to count against: detector count plus manual +/- minus NO REPs, within 0...the step's reps.
  public func repsDone(_ step: PlanStep, counted: Int) -> Int {
    let total = step.reps ?? 100
    return min(total, max(0, counted + repCorrection - noRepLog.count(inStep: step.index)))
  }

  /// Records the wall-ball reps of `step` (final when the step is left, provisional while it runs).
  public mutating func bank(step: PlanStep, repTimesMs: [Int64]) {
    guard step.activity == .wallBalls else { return }
    repsByStep[step.index] = repTimesMs
    correctionByStep[step.index] = repCorrection
  }

  /// Entering a wall-ball step. True when it is the first visit (the count starts at zero); false on an undo back
  /// into it or after a resume, when the earlier correction comes back.
  public mutating func enterWallBalls(_ step: PlanStep) -> Bool {
    let fresh = !enteredWallBalls.contains(step.index)
    enteredWallBalls.insert(step.index)
    repCorrection = fresh ? 0 : (correctionByStep[step.index] ?? 0)
    return fresh
  }

  /// Sets already passed (an undo back into the step, or a resume) are not announced again.
  public mutating func resetAnnouncedSets(for step: PlanStep, repsDone: Int) {
    announcedSets = []
    var cumulative = 0
    for (k, size) in step.sets.enumerated() {
      cumulative += size
      if repsDone >= cumulative { announcedSets.insert(k) }
    }
  }

  /// Sets completed since the last call, each with the size of the set that follows. Marks them announced.
  public mutating func newlyDoneSets(_ step: PlanStep, repsDone: Int) -> [(index: Int, next: Int?)] {
    var out: [(index: Int, next: Int?)] = []
    var cumulative = 0
    for (k, size) in step.sets.enumerated() {
      cumulative += size
      if repsDone >= cumulative, !announcedSets.contains(k) {
        announcedSets.insert(k)
        out.append((k, k + 1 < step.sets.count ? step.sets[k + 1] : nil))
      }
    }
    return out
  }

  /// The `coach.json` for this state. A step still open is closed at `endedAtEpochMs` (never before it started),
  /// as `SessionMachine.end` does for an early finish. Nil when the session never started.
  public func makeResult(early: Bool, endedAtEpochMs: Int64) -> CoachResult? {
    var s = self
    if let cur = s.machine.current {
      if cur.activity == .wallBalls { s.correctionByStep[cur.index] = s.repCorrection }
      s.machine.end(at: max(endedAtEpochMs, s.machine.splits.last?.startMs ?? endedAtEpochMs))
    }
    guard let started = s.machine.startMs else { return nil }
    let isEarly: Bool
    if case .finished(let e) = s.machine.phase { isEarly = e || early } else { isEarly = true }
    return CoachResult(
      plan: s.machine.plan, splits: s.machine.splits, early: isEarly, repTimesMs: s.repsByStep.values.flatMap { $0 }.sorted(),
      repCorrection: s.correctionByStep.values.reduce(0, +), startedAtEpochMs: started,
      endedAtEpochMs: s.machine.endMs ?? endedAtEpochMs, noReps: s.noRepLog.events)
  }

  /// Safe to index the plan with: the machine is consistent and every per-step key names a real step.
  public var isConsistent: Bool {
    let steps = machine.plan.steps
    func ok<S: Sequence>(_ keys: S) -> Bool where S.Element == Int { keys.allSatisfy { steps.indices.contains($0) } }
    return machine.isConsistent && ok(repsByStep.keys) && ok(correctionByStep.keys) && ok(enteredWallBalls)
      && ok(midCueDone) && ok(jogInDone) && noRepLog.events.allSatisfy { $0.stepIndex.map { steps.indices.contains($0) } ?? true }
  }
}
