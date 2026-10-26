import Foundation

/// When the NO REP button is up on a wall-ball step, and how long the Undo chip lasts after a tap.
/// The button shows only in a real rest: 4 s with no counted rep, or at a set end once the count has settled for 1.5 s.
/// It hides only on the next counted rep, so a slow rep cannot make it flicker.
public struct NoRepRest: Equatable {
  /// No counted rep for this long: the athlete is resting.
  public static let pauseMs: Int64 = 4000
  /// At a set end the button may come up sooner, but never within this long of the last counted rep.
  public static let settleMs: Int64 = 1500
  /// A "No rep noted" that cannot start within this long of the tap is dropped.
  public static let cueMaxAgeSeconds: TimeInterval = 5

  public private(set) var shown = false
  public private(set) var undoUntilMs: Int64 = 0
  private var lastCount: Int
  private var lastRepMs: Int64

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
      lastCount = count
      lastRepMs = nowMs
      shown = false
      return false
    }
    guard !shown, count > 0 else { return shown }
    let quiet = nowMs - lastRepMs
    var cumulative = 0
    let setEnd = sets.contains { cumulative += $0; return done == cumulative }
    if quiet >= Self.pauseMs || (setEnd && quiet >= Self.settleMs) { shown = true }
    return shown
  }

  /// A NO REP was tapped: the Undo chip is up for `NoRepLog.undoWindowSeconds`, whatever the athlete does next.
  public mutating func noted(nowMs: Int64) {
    undoUntilMs = nowMs + Int64(NoRepLog.undoWindowSeconds) * 1000
  }

  public mutating func clearUndo() { undoUntilMs = 0 }

  public func undoVisible(nowMs: Int64, taps: Int) -> Bool { nowMs < undoUntilMs && taps > 0 }
}
