import Foundation

/// When the NO REP button is up on a wall-ball step, and how long the Undo chip lasts after a tap.
/// The button shows only in a real rest: 4 s with no counted rep, or at a set end once the count has settled for 1.5 s.
/// It hides only on the next counted rep, so a slow rep cannot make it flicker.
public struct NoRepRest: Equatable {
  /// No counted rep for this long: the athlete is resting.
  public static let pauseMs: Int64 = 4000
  /// At a set end the button may come up sooner than `pauseMs`, but never within this long of the last counted rep,
  /// or 1.2x the athlete's median rep interval when that is longer: a slow thrower going straight into the next set
  /// must not see it.
  public static let settleMs: Int64 = 3000
  public static let settleIntervalFactor = 1.2
  private static let keptIntervals = 9
  /// A "No rep noted" that cannot start within this long of the tap is dropped.
  public static let cueMaxAgeSeconds: TimeInterval = 5

  public private(set) var shown = false
  public private(set) var undoUntilMs: Int64 = 0
  private var lastCount: Int
  private var lastRepMs: Int64
  private var intervals: [Int64] = []

  public init(count: Int = 0, nowMs: Int64 = 0) {
    lastCount = count
    lastRepMs = nowMs
  }

  /// A new step starts: no button, the clock restarts from `count`.
  public mutating func reset(count: Int, nowMs: Int64) {
    self = NoRepRest(count: count, nowMs: nowMs)
  }

  /// The athlete left the step: hide the button. A pending Undo chip is kept for its window.
  public mutating func hide() { shown = false }

  /// Call on every refresh with the raw rep count, the reps done and the set sizes. Returns whether the button is up.
  @discardableResult
  public mutating func update(nowMs: Int64, count: Int, done: Int, sets: [Int]) -> Bool {
    if count != lastCount {
      if count > lastCount, lastCount > 0 {
        intervals.append(nowMs - lastRepMs)
        if intervals.count > Self.keptIntervals { intervals.removeFirst() }
      }
      lastCount = count
      lastRepMs = nowMs
      shown = false
      return false
    }
    guard !shown, count > 0 else { return shown }
    let quiet = nowMs - lastRepMs
    var cumulative = 0
    let setEnd = sets.contains { cumulative += $0; return done == cumulative }
    if quiet >= Self.pauseMs || (setEnd && quiet >= settleMs) { shown = true }
    return shown
  }

  /// The quiet time a set end needs before the button shows.
  public var settleMs: Int64 {
    guard !intervals.isEmpty else { return Self.settleMs }
    let sorted = intervals.sorted()
    let n = sorted.count
    let median = n % 2 == 1 ? Double(sorted[n / 2]) : Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2
    return max(Self.settleMs, Int64((median * Self.settleIntervalFactor).rounded()))
  }

  /// A NO REP was tapped: the Undo chip is up for `NoRepLog.undoWindowSeconds`, whatever the athlete does next.
  public mutating func noted(nowMs: Int64) {
    undoUntilMs = nowMs + Int64(NoRepLog.undoWindowSeconds) * 1000
  }

  public mutating func clearUndo() { undoUntilMs = 0 }

  public func undoVisible(nowMs: Int64, taps: Int) -> Bool { nowMs < undoUntilMs && taps > 0 }
}
