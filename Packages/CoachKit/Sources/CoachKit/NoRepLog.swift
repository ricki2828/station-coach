import Foundation

/// The NO REP taps of a session, in order. Reps left on the watch is derived from `count(inStep:)`, so removing a tap restores it.
public struct NoRepLog: Equatable {
  /// How long the Undo chip stays up after a tap.
  public static let undoWindowSeconds = 4

  public private(set) var events: [NoRepEvent] = []

  public init(events: [NoRepEvent] = []) { self.events = events }

  public mutating func add(_ event: NoRepEvent) { events.append(event) }

  public func count(inStep step: Int) -> Int { events.filter { $0.stepIndex == step }.count }

  /// Removes the latest tap made in `step` and returns it; nil when there is none.
  @discardableResult
  public mutating func undoLast(inStep step: Int) -> NoRepEvent? {
    guard let i = events.lastIndex(where: { $0.stepIndex == step }) else { return nil }
    return events.remove(at: i)
  }

  public mutating func reset() { events = [] }
}
