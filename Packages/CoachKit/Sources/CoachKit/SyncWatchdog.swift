import Foundation

/// Phone side: sessions the watch said it finished that have not fully arrived. After `graceSeconds` without
/// any file for such a session, while the phone app is open, the summary shows the sync-failed state.
public struct SyncWatchdog: Codable, Equatable {
  public static let graceSeconds: TimeInterval = 180

  /// Session id -> when the phone last heard anything about it (the finish notice or a file).
  private var waiting: [String: TimeInterval] = [:]

  public init() {}

  public var pending: [String] { waiting.keys.sorted() }

  /// The watch finished `session` (the notice reached the phone at `t`).
  public mutating func finished(session: String, at t: TimeInterval) {
    if waiting[session] == nil { waiting[session] = t }
  }

  /// A file of `session` arrived: progress, so the clock restarts.
  public mutating func activity(session: String, at t: TimeInterval) {
    if waiting[session] != nil { waiting[session] = t }
  }

  /// Every file of `session` arrived intact.
  public mutating func complete(session: String) { waiting[session] = nil }

  /// A session the phone has given up waiting for. `openSince` is when the app last came to the front:
  /// time spent closed does not count, so a notice delivered late never fails instantly.
  public func failedSession(now: TimeInterval, openSince: TimeInterval) -> String? {
    waiting
      .filter { now - max($0.value, openSince) > Self.graceSeconds }
      .min { $0.value < $1.value }?.key
  }
}
