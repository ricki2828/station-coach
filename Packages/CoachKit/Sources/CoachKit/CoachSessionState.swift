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
  /// Start of the split that began each wall-ball step's current attempt. A later start means a new attempt (the step was
  /// skipped or moved and is now done afresh). Optional so checkpoints from before skipping still decode.
  public var attemptStart: [Int: Int64]?

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
  /// `splitStartMs` is the start of the open split: a later one than the attempt on record means a new attempt, which
  /// starts from nothing (the reps, correction and no-reps of the abandoned one are dropped).
  public mutating func enterWallBalls(_ step: PlanStep, splitStartMs: Int64 = 0) -> Bool {
    let idx = step.index
    let earlier = attemptStart?[idx]
    let newAttempt = earlier.map { splitStartMs > $0 } ?? false
    let fresh = !enteredWallBalls.contains(idx) || newAttempt
    enteredWallBalls.insert(idx)
    if fresh {
      if attemptStart == nil { attemptStart = [:] }
      attemptStart?[idx] = splitStartMs
      repsByStep[idx] = nil
      correctionByStep[idx] = nil
      noRepLog.removeAll(inStep: idx)
      repCorrection = 0
    } else {
      repCorrection = correctionByStep[idx] ?? 0
    }
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
    // A skipped station has no reps and no no-reps: whatever was counted before the skip is not part of the result.
    let done = s.machine.doneSteps
    s.repsByStep = s.repsByStep.filter { done.contains($0.key) }
    s.correctionByStep = s.correctionByStep.filter { done.contains($0.key) }
    s.noRepLog = NoRepLog(events: s.noRepLog.events.filter { $0.stepIndex.map(done.contains) ?? true })
    // A station moved to later and then done has two attempts: only what falls inside the done split's window is its own.
    var windows: [Int: (Int64, Int64)] = [:]
    for sp in s.machine.splits where !sp.isSkipped {
      if let end = sp.endMs, s.machine.splits.contains(where: { $0.stepIndex == sp.stepIndex && $0.isSkipped }) { windows[sp.stepIndex] = (sp.startMs, end) }
    }
    for (idx, w) in windows {
      s.repsByStep[idx] = s.repsByStep[idx]?.filter { $0 >= w.0 && $0 <= w.1 }
      s.noRepLog = NoRepLog(events: s.noRepLog.events.filter { $0.stepIndex != idx || ($0.tMs >= w.0 && $0.tMs <= w.1) })
    }
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
