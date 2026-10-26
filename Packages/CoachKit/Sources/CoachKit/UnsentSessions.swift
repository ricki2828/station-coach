import Foundation

/// Whether the watch still has sessions on their way, for the " (sync your watch for the full week)" caveat. A folder that
/// stopped arriving long ago is abandoned, not unsent: otherwise one dead partial transfer would put the caveat on every
/// Monday notice forever.
public enum UnsentSessions {
  /// A partial folder counts for this long after its session started.
  public static let liveDays = 3.0

  /// A session id starts with its UTC start time: `20261026T100000Z-ab12cd`.
  public static func startDate(ofSessionId id: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.date(from: String(id.prefix(16)))
  }

  /// `partialIds`: folders on the phone that are not complete. `pendingIds`: sessions the watch announced or is still sending
  /// that are not complete here (the watchdog prunes these, so they are live by construction).
  public static func hasUnsent(partialIds: [String], pendingIds: [String], now: Date) -> Bool {
    if !pendingIds.isEmpty { return true }
    return partialIds.contains { id in
      guard let start = startDate(ofSessionId: id) else { return false }
      let age = now.timeIntervalSince(start)
      return age >= 0 && age <= liveDays * 86_400
    }
  }
}

/// The notification is rebuilt from the loaded sessions. Until the first load has landed there is nothing to build from, and
/// rebuilding from an empty list would cancel the pending notification: wait.
public struct NoticeRescheduleGate: Equatable {
  public private(set) var loadReady = false
  public init() {}
  public var mayReschedule: Bool { loadReady }
  public mutating func loadLanded() { loadReady = true }
}
