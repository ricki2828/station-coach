import Foundation

/// Achieved sample rate from sample timestamps (seconds, any monotonic base).
public struct RateMeter: Equatable {
  public private(set) var count = 0
  private var first: Double?
  private var last: Double?

  public init() {}

  public mutating func add(_ t: Double) {
    if first == nil { first = t }
    last = t
    count += 1
  }

  /// (n - 1) intervals over the time spanned; nil until two samples span a positive time.
  public var hz: Double? {
    guard count > 1, let first, let last, last > first else { return nil }
    return Double(count - 1) / (last - first)
  }

  public mutating func reset() { self = RateMeter() }
}

/// Keeps roughly one sample per 1/targetHz so a 800 Hz stream can be stored at 100 Hz.
public struct Decimator {
  public let targetHz: Double
  private let minGap: Double
  private var lastKept: Double?

  public init(targetHz: Double) {
    self.targetHz = targetHz
    self.minGap = 0.9 / targetHz
  }

  public mutating func keep(_ t: Double) -> Bool {
    if let lastKept, t - lastKept < minGap { return false }
    lastKept = t
    return true
  }
}
