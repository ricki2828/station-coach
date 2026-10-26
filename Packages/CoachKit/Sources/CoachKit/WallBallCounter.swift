import Foundation

/// Heuristic wall-ball rep counter: peaks in the smoothed magnitude of wrist (user) acceleration, in g.
/// A beta. It never blocks anything: feed it samples, read `count` and `confidence`; the athlete can correct.
public struct WallBallCounter {
  public enum Confidence { case high, low }

  /// Open athletes rarely go under about 1.8 s a rep. A catch peak 1.0-1.5 s after the throw must not count too.
  public static let defaultMinInterval: TimeInterval = 1.7
  /// Jogging in and picking up the ball look like reps; skip the start of the station.
  public static let defaultIgnoreFirst: TimeInterval = 4
  public static let minThreshold = 0.6
  /// Intervals longer than this are rests between sets, not rep-to-rep rhythm.
  public static let restGap: TimeInterval = 8

  public private(set) var count = 0
  /// Sample-clock time of each counted rep.
  public private(set) var repTimes: [TimeInterval] = []

  private var smooth: Double?
  private var envelope = 0.0
  private var prevT = 0.0, prevS = 0.0, prevPrevS = 0.0
  private var samples = 0
  private var lastPeakT: TimeInterval = -.infinity

  private let minInterval: TimeInterval
  private let ignoreFirst: TimeInterval
  private var firstT: TimeInterval?

  public init(minInterval: TimeInterval = WallBallCounter.defaultMinInterval, ignoreFirstSeconds: TimeInterval = WallBallCounter.defaultIgnoreFirst) {
    self.minInterval = minInterval
    self.ignoreFirst = ignoreFirstSeconds
  }

  /// Returns true when this sample completed a rep (the peak is detected one sample late).
  @discardableResult
  public mutating func add(t: TimeInterval, magnitude: Double) -> Bool {
    if firstT == nil { firstT = t }
    let s = smooth.map { $0 * 0.8 + magnitude * 0.2 } ?? magnitude
    smooth = s
    envelope = max(s, envelope * 0.9995)
    defer {
      prevPrevS = prevS
      prevS = s
      prevT = t
      samples += 1
    }
    guard samples >= 2 else { return false }
    let threshold = max(Self.minThreshold, 0.5 * envelope)
    if prevS > prevPrevS, prevS >= s, prevS > threshold, prevT - lastPeakT >= minInterval, prevT - (firstT ?? t) >= ignoreFirst {
      lastPeakT = prevT
      count += 1
      repTimes.append(prevT)
      return true
    }
    return false
  }

  /// Low until 3 reps are in, and when the last intervals are uneven (not a steady rhythm).
  public var confidence: Confidence {
    guard repTimes.count >= 3 else { return .low }
    let recent = repTimes.suffix(6)
    let gaps = zip(recent.dropFirst(), recent).map { $0 - $1 }.filter { $0 < Self.restGap }
    guard gaps.count >= 2 else { return .high }
    let mean = gaps.reduce(0, +) / Double(gaps.count)
    let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
    return mean > 0 && variance.squareRoot() / mean <= 0.4 ? .high : .low
  }
}
