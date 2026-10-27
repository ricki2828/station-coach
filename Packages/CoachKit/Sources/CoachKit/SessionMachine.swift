import Foundation

public struct StepSplit: Codable, Equatable {
  public let stepIndex: Int
  public let startMs: Int64
  public var endMs: Int64?
  /// True when the step was skipped, or moved to later (the move leaves a skipped split behind). Never counts as done: no
  /// seconds, no volume, no delta. Absent in files from before skipping.
  public var skipped: Bool?

  public init(stepIndex: Int, startMs: Int64, endMs: Int64? = nil, skipped: Bool? = nil) {
    self.stepIndex = stepIndex
    self.startMs = startMs
    self.endMs = endMs
    self.skipped = skipped
  }

  public var isSkipped: Bool { skipped == true }
}

/// ready -> step 0 -> step 1 -> ... -> finished. `advance` is the NEXT button or the pinch; `undo` goes back one action;
/// `end` finishes early. A station can be skipped (`skip`) or moved after the next station (`skip(later: true)`); a moved
/// station with nothing after it to wait behind is offered again at the end (`awaitingLeftover`). All times are epoch
/// milliseconds passed in, so it is deterministic.
public struct SessionMachine: Codable, Equatable {
  public enum Phase: Codable, Equatable {
    case ready
    case running
    /// Every step is done or skipped but a moved station is still undone: "Do it now" or "Finish without it".
    case awaitingLeftover
    case finished(early: Bool)
  }

  public enum Advance: Equatable {
    case started(Int)
    case finished
    /// The last step is done but a moved station is still waiting.
    case leftover
    /// Within `debounceMs` of the previous advance.
    case ignored
    case notRunning
  }

  /// A second advance inside this window is a double fire and is ignored.
  public static let debounceMs: Int64 = 3_000

  /// What `undo` restores: the state just before an advance, skip or move.
  struct Snapshot: Codable, Equatable {
    var splits: [StepSplit]
    var order: [Int]
    var pos: Int
    var deferred: [Int]
    var phase: Phase
  }

  public let plan: SessionPlan
  public private(set) var phase: Phase = .ready
  public private(set) var splits: [StepSplit] = []
  public private(set) var startMs: Int64?
  public private(set) var endMs: Int64?
  private var lastAdvanceMs: Int64?
  /// Plan step indices in the order they are done. Starts as 0, 1, 2 ...; a moved station is re-inserted after the next one.
  public private(set) var order: [Int]
  /// Position of the current step in `order`.
  public private(set) var pos = 0
  /// Moved stations with nothing after them to wait behind, offered again at the end.
  public private(set) var deferred: [Int] = []
  private var history: [Snapshot] = []

  public init(plan: SessionPlan) {
    self.plan = plan
    self.order = Array(plan.steps.indices)
  }

  private enum CodingKeys: String, CodingKey {
    case plan, phase, splits, startMs, endMs, lastAdvanceMs, order, pos, deferred, history
  }

  /// Checkpoints from before skipping have no `order`: it is the plan order.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    plan = try c.decode(SessionPlan.self, forKey: .plan)
    phase = try c.decode(Phase.self, forKey: .phase)
    splits = try c.decode([StepSplit].self, forKey: .splits)
    startMs = try c.decodeIfPresent(Int64.self, forKey: .startMs)
    endMs = try c.decodeIfPresent(Int64.self, forKey: .endMs)
    lastAdvanceMs = try c.decodeIfPresent(Int64.self, forKey: .lastAdvanceMs)
    order = try c.decodeIfPresent([Int].self, forKey: .order) ?? Array(plan.steps.indices)
    pos = try c.decodeIfPresent(Int.self, forKey: .pos) ?? max(0, (splits.last?.stepIndex ?? 0))
    deferred = try c.decodeIfPresent([Int].self, forKey: .deferred) ?? []
    history = try c.decodeIfPresent([Snapshot].self, forKey: .history) ?? []
  }

  public var currentIndex: Int? { phase == .running ? splits.last?.stepIndex : nil }
  public var current: PlanStep? { currentIndex.map { plan.steps[$0] } }
  public var next: PlanStep? {
    guard phase == .running, pos + 1 < order.count else { return nil }
    return plan.steps[order[pos + 1]]
  }

  /// Whether the NEXT button ends the session: nothing follows and nothing is waiting.
  public var isLastStep: Bool { next == nil && deferred.isEmpty }

  /// Plan steps that have a finished (not skipped) split.
  public var doneSteps: Set<Int> { Set(splits.filter { $0.endMs != nil && !$0.isSkipped }.map(\.stepIndex)) }

  /// The moved station that is still to do, once everything else is done.
  public var leftoverStep: PlanStep? { phase == .awaitingLeftover ? deferred.first.map { plan.steps[$0] } : nil }

  /// Stations skipped (or moved and never done): a split flagged skipped with no completed one for the step.
  public var skippedStations: [Int] {
    let done = doneSteps
    return Array(Set(splits.filter { $0.isSkipped && !plan.steps[$0.stepIndex].isRun && !done.contains($0.stepIndex) }.map(\.stepIndex))).sorted()
  }

  public mutating func start(at ms: Int64) {
    guard phase == .ready else { return }
    phase = .running
    startMs = ms
    pos = 0
    splits = [StepSplit(stepIndex: order[0], startMs: ms, endMs: nil)]
    lastAdvanceMs = nil
    history = []
  }

  private func snapshot() -> Snapshot { Snapshot(splits: splits, order: order, pos: pos, deferred: deferred, phase: phase) }

  /// Closes the open split at `ms` (flagged skipped when asked) and moves on: the next step in order, the leftover prompt, or the end.
  private mutating func leave(at ms: Int64, skipped: Bool) -> Advance {
    history.append(snapshot())
    splits[splits.count - 1].endMs = ms
    if skipped { splits[splits.count - 1].skipped = true }
    return moveOn(at: ms)
  }

  private mutating func moveOn(at ms: Int64) -> Advance {
    if pos + 1 < order.count {
      pos += 1
      splits.append(StepSplit(stepIndex: order[pos], startMs: ms, endMs: nil))
      return .started(order[pos])
    }
    if !deferred.isEmpty {
      phase = .awaitingLeftover
      return .leftover
    }
    phase = .finished(early: false)
    endMs = ms
    return .finished
  }

  @discardableResult
  public mutating func advance(at ms: Int64) -> Advance {
    guard phase == .running, currentIndex != nil else { return .notRunning }
    if let last = lastAdvanceMs, ms - last < Self.debounceMs { return .ignored }
    lastAdvanceMs = ms
    return leave(at: ms, skipped: false)
  }

  /// Skips the station in progress, or (`later`) moves it after the next station. Stations only: a run is never skipped.
  /// With nothing after it to wait behind, a moved station is offered again at the end.
  @discardableResult
  public mutating func skip(later: Bool, at ms: Int64) -> Advance {
    guard phase == .running, let step = current else { return .notRunning }
    guard !step.isRun else { return .ignored }
    if let last = lastAdvanceMs, ms - last < Self.debounceMs { return .ignored }
    lastAdvanceMs = ms
    guard later else { return leave(at: ms, skipped: true) }
    history.append(snapshot())
    splits[splits.count - 1].endMs = ms
    splits[splits.count - 1].skipped = true
    let moved = order.remove(at: pos)
    // After the next station: its index, shifted down by the removal, is where the moved one goes behind it.
    if let j = (pos..<order.count).first(where: { !plan.steps[order[$0]].isRun }) {
      order.insert(moved, at: j + 1)
    } else {
      deferred.append(moved)
    }
    pos -= 1 // moveOn steps forward to what now sits at the old position
    return moveOn(at: ms)
  }

  /// "Do it now": the moved station that was left over becomes the last step.
  @discardableResult
  public mutating func doLeftover(at ms: Int64) -> Advance {
    guard phase == .awaitingLeftover, !deferred.isEmpty else { return .notRunning }
    history.append(snapshot())
    let step = deferred.removeFirst()
    order.append(step)
    pos = order.count - 1
    phase = .running
    splits.append(StepSplit(stepIndex: step, startMs: ms, endMs: nil))
    lastAdvanceMs = ms
    return .started(step)
  }

  /// "Finish without it": the left-over station stays skipped.
  @discardableResult
  public mutating func finishWithoutLeftover(at ms: Int64) -> Advance {
    guard phase == .awaitingLeftover else { return .notRunning }
    history.append(snapshot())
    deferred = []
    phase = .finished(early: false)
    endMs = ms
    return .finished
  }

  /// Back one action (an advance, a skip, a move, or a finish), reopening the step it left. Does nothing from the first step.
  /// Returns whether it moved.
  @discardableResult
  public mutating func undo(at ms: Int64) -> Bool {
    switch phase {
    case .finished(early: true), .ready:
      return false
    default:
      guard let snap = history.popLast() else { return false }
      splits = snap.splits
      order = snap.order
      pos = snap.pos
      deferred = snap.deferred
      phase = snap.phase
      endMs = nil
      lastAdvanceMs = nil
      return true
    }
  }

  /// Ends now with whatever is done. The step in progress is closed.
  public mutating func end(at ms: Int64) {
    switch phase {
    case .running:
      splits[splits.count - 1].endMs = ms
    case .awaitingLeftover:
      break // the last split is already closed
    default:
      return
    }
    phase = .finished(early: true)
    endMs = ms
  }

  /// Whether a machine read back from disk can be trusted to index the plan: every split names a real step, only the
  /// running step is open, times do not run backwards, and the order is a permutation of real steps with the current
  /// step where `pos` says. A checkpoint that fails this is treated as corrupt.
  public var isConsistent: Bool {
    guard !plan.steps.isEmpty else { return false }
    let valid = plan.steps.indices
    guard order.allSatisfy(valid.contains), Set(order).count == order.count, deferred.allSatisfy(valid.contains) else { return false }
    for (i, s) in splits.enumerated() {
      guard valid.contains(s.stepIndex) else { return false }
      if let end = s.endMs, end < s.startMs { return false }
      if i > 0 {
        guard let prevEnd = splits[i - 1].endMs, prevEnd <= s.startMs else { return false }
      }
    }
    switch phase {
    case .ready:
      return splits.isEmpty
    case .running:
      guard startMs != nil, splits.first?.startMs == startMs, splits.last?.endMs == nil else { return false }
      return order.indices.contains(pos) && order[pos] == splits.last?.stepIndex
    case .awaitingLeftover:
      return startMs != nil && !splits.isEmpty && splits.last?.endMs != nil && !deferred.isEmpty
    case .finished:
      return startMs != nil && endMs != nil && !splits.isEmpty && splits.last?.endMs != nil
    }
  }

  // MARK: Time maths

  public func totalElapsedSeconds(at ms: Int64) -> Int {
    guard let s = startMs else { return 0 }
    return Int(((endMs ?? ms) - s) / 1000)
  }

  public func stepElapsedSeconds(at ms: Int64) -> Int {
    guard let last = splits.last else { return 0 }
    return Int(((last.endMs ?? ms) - last.startMs) / 1000)
  }

  /// Seconds behind plan (positive) or ahead (negative): finished steps' actual minus planned,
  /// plus any overrun of the step in progress. Time inside the current target is not counted yet.
  public func deltaSeconds(at ms: Int64) -> Int {
    DeltaMath.delta(plan: plan, splits: splits, nowMs: ms)
  }

  /// The M1 label for the current moment: a run that follows a station starts as `transition`.
  public func label(at ms: Int64) -> Activity? {
    guard let step = current else { return nil }
    if step.isRun, step.index > 0, stepElapsedSeconds(at: ms) < plan.transitionSeconds { return .transition }
    return step.activity
  }
}

public enum DeltaMath {
  public static func delta(plan: SessionPlan, splits: [StepSplit], nowMs: Int64) -> Int {
    var total = 0
    for s in splits where !s.isSkipped { // a skipped step is out of both sides, so the delta stays comparable
      let target = plan.referenceSeconds(at: s.stepIndex)
      if let end = s.endMs {
        total += Int((end - s.startMs) / 1000) - target
      } else {
        total += max(0, Int((nowMs - s.startMs) / 1000) - target)
      }
    }
    return total
  }

  /// Rounded to 5 s for speech; |delta| under 10 s counts as on plan.
  public static func spokenBucket(_ seconds: Int) -> Int {
    abs(seconds) < 10 ? 0 : Int((Double(seconds) / 5).rounded()) * 5
  }
}
