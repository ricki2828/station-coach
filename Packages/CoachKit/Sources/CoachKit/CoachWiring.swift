import Foundation

// Logic the watch controllers use, kept here (no WatchKit) so it is unit-tested on the host.

/// Wall-ball rep counter shared with the motion thread. Holds the detector for the step being counted, plus rep times
/// counted before a relaunch (or before an undo across steps) that the detector itself no longer has.
public final class WallBallTally {
  private let lock = NSLock()
  private var counter = WallBallCounter()
  private var enabled = false
  private var carried: [Double] = []
  private var owner: Int?

  public init() {}

  /// Start counting `step`. `fresh` starts from zero. Otherwise the earlier count carries on: from the detector when it
  /// still holds that step (undo back into it), else from `earlier` (after a relaunch, or an undo across steps).
  public func begin(step: Int, fresh: Bool, earlier: [Double]) {
    lock.lock(); defer { lock.unlock() }
    if fresh {
      counter = WallBallCounter()
      carried = []
      owner = step
    } else if owner != step {
      counter = WallBallCounter()
      carried = earlier
      owner = step
    }
    enabled = true
  }

  public func pause() {
    lock.lock(); defer { lock.unlock() }
    enabled = false
  }

  public func feed(_ t: Double, _ magnitude: Double) {
    lock.lock(); defer { lock.unlock() }
    guard enabled else { return }
    counter.add(t: t, magnitude: magnitude)
  }

  public func snapshot() -> (count: Int, confidence: WallBallCounter.Confidence, times: [Double]) {
    lock.lock(); defer { lock.unlock() }
    return (carried.count + counter.count, counter.confidence, carried + counter.repTimes)
  }

  /// Rep times (s) as the epoch milliseconds the checkpoint and `coach.json` store.
  public static func milliseconds(_ seconds: [Double]) -> [Int64] { seconds.map { Int64(($0 * 1000).rounded()) } }
}

/// Writes `coach-checkpoint.json` for a running session: banks the live rep times of the step in progress into the saved
/// state, numbers each write, and reports a failed write once.
public final class CoachCheckpointer {
  public private(set) var seq: Int
  /// Rep count at the last write; nil before the first.
  public private(set) var lastRepCount: Int?
  private var failureReported = false

  public init(startingSeq: Int = 0) { seq = startingSeq }

  /// True when the count changed since the last write (a rep was counted), so the 1 s tick writes at most once per rep.
  public func repCountChanged(_ count: Int) -> Bool { lastRepCount != count }

  /// Returns nil on success or when it already reported a failure; otherwise the first failure's description.
  @discardableResult
  public func save(_ state: CoachSessionState, liveRepTimesMs: [Int64], liveCount: Int, folder: URL, nowMs: Int64) -> String? {
    // Only a running session is worth resuming: a finished one has coach.json.
    guard let step = state.machine.current else { return nil }
    var s = state
    s.bank(step: step, repTimesMs: liveRepTimesMs) // provisional times of the step in progress
    lastRepCount = liveCount
    let cp = CoachCheckpoint(sessionId: folder.lastPathComponent, savedAtEpochMs: nowMs, seq: seq, state: s)
    seq += 1
    do {
      try CoachCheckpoint.write(cp, to: folder)
      return nil
    } catch {
      guard !failureReported else { return nil }
      failureReported = true
      return "\(error)"
    }
  }
}

/// Holds the "recover the session" request until the app has built its controllers, then runs it once.
public final class RecoveryTrigger {
  private var handler: (() -> Void)?
  private var pending = false

  public init() {}

  public func install(_ handler: @escaping () -> Void) {
    self.handler = handler
    if pending { request() }
  }

  public func request() {
    guard let handler else { pending = true; return }
    pending = false
    handler()
  }
}

/// Decides what a recording fault does to the screen. The first time a fault is raised it is a full-screen alarm. Once the
/// athlete has tapped OK, the same fault never comes back as an alarm: it can only reach them as a non-blocking toast, at
/// most once per `toastEvery` seconds. It alarms again only if the state changes: the fault cleared and returned, or it is
/// a different fault.
public struct AlarmGate {
  public enum Action: Equatable { case alarm, toast, ignore }

  public static let toastEvery: TimeInterval = 120

  public private(set) var current: String?
  /// Faults raised while another alarm was up, in order. None is dropped: `dismiss()` hands them back one at a time.
  public private(set) var pending: [String] = []
  private var acknowledged = Set<String>()
  private var lastToast: [String: TimeInterval] = [:]

  public init() {}

  public mutating func raise(_ message: String, at now: TimeInterval) -> Action {
    if acknowledged.contains(message) {
      if let last = lastToast[message], now - last < Self.toastEvery { return .ignore }
      lastToast[message] = now
      return .toast
    }
    if current != nil {
      // One alarm on screen at a time. A different fault waits its turn (a recurrence of the one showing needs no second copy).
      if message != current, !pending.contains(message) { pending.append(message) }
      return .ignore
    }
    current = message
    return .alarm
  }

  /// The athlete tapped OK. Returns the next waiting fault, which is now the current alarm and must be shown; nil if none.
  @discardableResult
  public mutating func dismiss() -> String? {
    if let m = current { acknowledged.insert(m) }
    current = nil
    while !pending.isEmpty {
      let next = pending.removeFirst()
      if acknowledged.contains(next) { continue }
      current = next
      return next
    }
    return nil
  }

  /// The fault has cleared (samples are flowing again, the stream is back). A later recurrence alarms afresh.
  public mutating func clear(_ message: String) {
    acknowledged.remove(message)
    lastToast[message] = nil
    pending.removeAll { $0 == message }
  }

  /// A new session: forget everything.
  public mutating func reset() { self = AlarmGate() }
}
