import Foundation

public struct StepSplit: Codable, Equatable {
  public let stepIndex: Int
  public let startMs: Int64
  public var endMs: Int64?

  public init(stepIndex: Int, startMs: Int64, endMs: Int64? = nil) {
    self.stepIndex = stepIndex
    self.startMs = startMs
    self.endMs = endMs
  }
}

/// ready -> step 0 -> step 1 -> ... -> finished. `advance` is the NEXT button or the pinch; `undo` goes
/// back one step; `end` finishes early. All times are epoch milliseconds passed in, so it is deterministic.
public struct SessionMachine: Codable, Equatable {
  public enum Phase: Codable, Equatable {
    case ready
    case running
    case finished(early: Bool)
  }

  public enum Advance: Equatable {
    case started(Int)
    case finished
    /// Within `debounceMs` of the previous advance.
    case ignored
    case notRunning
  }

  /// A second advance inside this window is a double fire and is ignored.
  public static let debounceMs: Int64 = 3_000

  public let plan: SessionPlan
  public private(set) var phase: Phase = .ready
  public private(set) var splits: [StepSplit] = []
  public private(set) var startMs: Int64?
  public private(set) var endMs: Int64?
  private var lastAdvanceMs: Int64?

  public init(plan: SessionPlan) { self.plan = plan }

  public var currentIndex: Int? { phase == .running ? splits.last?.stepIndex : nil }
  public var current: PlanStep? { currentIndex.map { plan.steps[$0] } }
  public var next: PlanStep? {
    guard let i = currentIndex, i + 1 < plan.steps.count else { return nil }
    return plan.steps[i + 1]
  }

  public mutating func start(at ms: Int64) {
    guard phase == .ready else { return }
    phase = .running
    startMs = ms
    splits = [StepSplit(stepIndex: 0, startMs: ms, endMs: nil)]
    lastAdvanceMs = nil
  }

  @discardableResult
  public mutating func advance(at ms: Int64) -> Advance {
    guard phase == .running, let i = currentIndex else { return .notRunning }
    if let last = lastAdvanceMs, ms - last < Self.debounceMs { return .ignored }
    lastAdvanceMs = ms
    splits[splits.count - 1].endMs = ms
    if i + 1 < plan.steps.count {
      splits.append(StepSplit(stepIndex: i + 1, startMs: ms, endMs: nil))
      return .started(i + 1)
    }
    phase = .finished(early: false)
    endMs = ms
    return .finished
  }

  /// Back to the previous step, reopening it. From the first step it does nothing. Returns whether it moved.
  @discardableResult
  public mutating func undo(at ms: Int64) -> Bool {
    switch phase {
    case .running:
      guard splits.count > 1 else { return false }
      splits.removeLast()
      splits[splits.count - 1].endMs = nil
      lastAdvanceMs = nil
      return true
    case .finished(early: false):
      splits[splits.count - 1].endMs = nil
      phase = .running
      endMs = nil
      lastAdvanceMs = nil
      return true
    default:
      return false
    }
  }

  /// Ends now with whatever is done. The step in progress is closed.
  public mutating func end(at ms: Int64) {
    guard phase == .running else { return }
    splits[splits.count - 1].endMs = ms
    phase = .finished(early: true)
    endMs = ms
  }

  /// Whether a machine read back from disk can be trusted to index the plan: every split names a real step, only the
  /// running step is open, and times do not run backwards. A checkpoint that fails this is treated as corrupt.
  public var isConsistent: Bool {
    guard !plan.steps.isEmpty else { return false }
    for (i, s) in splits.enumerated() {
      guard plan.steps.indices.contains(s.stepIndex) else { return false }
      if let end = s.endMs, end < s.startMs { return false }
      if i > 0 {
        guard let prevEnd = splits[i - 1].endMs, prevEnd <= s.startMs else { return false }
      }
    }
    switch phase {
    case .ready:
      return splits.isEmpty
    case .running:
      return startMs != nil && splits.first?.startMs == startMs && splits.last?.endMs == nil
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
    for s in splits {
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
