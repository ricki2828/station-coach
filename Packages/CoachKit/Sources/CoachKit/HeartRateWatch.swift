import Foundation

/// Decides whether heart rate should be called "off" during a session. HealthKit never says whether a
/// read was declined, so the only evidence is samples: none within `firstSampleDeadline` of the start (a cold start can take 15 s or more),
/// or none for `gapDeadline` after earlier ones (a strap-less wrist, a loose band).
public struct HeartRateWatch: Equatable {
  public static let firstSampleDeadline: TimeInterval = 30
  public static let gapDeadline: TimeInterval = 60

  private var startedAt: TimeInterval?
  private var lastSampleAt: TimeInterval?

  public init() {}

  public var everSampled: Bool { lastSampleAt != nil }

  public mutating func start(at t: TimeInterval) {
    startedAt = t
    lastSampleAt = nil
  }

  public mutating func sample(at t: TimeInterval) { lastSampleAt = t }

  public mutating func stop() { startedAt = nil }

  public func isOff(at t: TimeInterval) -> Bool {
    guard let startedAt else { return false }
    if let last = lastSampleAt { return t - last > Self.gapDeadline }
    return t - startedAt > Self.firstSampleDeadline
  }

  /// True if a session that ran until `t` never produced a sample (so the next Ready screen can warn).
  public func missedEntireSession(endingAt t: TimeInterval) -> Bool {
    guard let startedAt else { return false }
    return lastSampleAt == nil && t - startedAt > Self.firstSampleDeadline
  }
}
