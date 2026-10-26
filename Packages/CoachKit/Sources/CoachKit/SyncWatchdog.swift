import Foundation

/// Phone side: sessions the watch said it finished that have not fully arrived. After `graceSeconds` without
/// any file for such a session, while the phone app is open, the summary shows the sync-failed state.
public struct SyncWatchdog: Codable, Equatable {
  public static let graceSeconds: TimeInterval = 180
  /// An entry this old is dropped: a session deleted on the watch, or lost, must not hold the summary on "failed" for good.
  public static let expirySeconds: TimeInterval = 24 * 3600

  /// Session id -> when the phone last heard anything about it (the finish notice or a file).
  private var waiting: [String: TimeInterval] = [:]

  public init() {}

  public var pending: [String] { waiting.keys.sorted() }

  /// The watch finished `session` (the notice reached the phone at `t`).
  public mutating func finished(session: String, at t: TimeInterval) {
    if waiting[session] == nil { waiting[session] = t }
  }

  /// A file of `session` arrived, or the watch reported it is still sending (a heartbeat): the clock restarts.
  /// One motion file can take longer than the grace period on its own, and the phone gets no progress events for it.
  public mutating func activity(session: String, at t: TimeInterval) {
    if waiting[session] != nil { waiting[session] = t }
  }

  /// Every file of `session` arrived intact.
  public mutating func complete(session: String) { waiting[session] = nil }

  /// A session the phone has given up waiting for. `openSince` is when the app last came to the front:
  /// time spent closed does not count, so a notice delivered late never fails instantly.
  public func failedSession(now: TimeInterval, openSince: TimeInterval) -> String? {
    waiting
      .filter { now - $0.value <= Self.expirySeconds && now - max($0.value, openSince) > Self.graceSeconds }
      .max { $0.key < $1.key }?.key // session ids sort by start time: the newest
  }

  /// Drops entries past `expirySeconds`.
  public mutating func prune(now: TimeInterval) {
    waiting = waiting.filter { now - $0.value <= Self.expirySeconds }
  }

  /// A failed session hides the summary only until a newer session has arrived complete: the newest result wins.
  public static func showsFailed(failedId: String?, newestReadyId: String?) -> Bool {
    guard let failedId else { return false }
    guard let newestReadyId else { return true }
    return newestReadyId < failedId
  }
}
