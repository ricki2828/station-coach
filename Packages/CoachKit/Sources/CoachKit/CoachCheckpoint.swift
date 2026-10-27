import Foundation

/// `coach-checkpoint.json`: the coach state of a running session, rewritten atomically on every change that matters
/// (step change, NO REP, +/-, undo, a counted rep). A crash or relaunch resumes from it, or, when the workout cannot be
/// reattached, turns it into `coach.json` so the splits still reach History.
public struct CoachCheckpoint: Codable, Equatable {
  public static let fileName = "coach-checkpoint.json"
  /// The copy before the latest write: used when the latest is unreadable.
  public static let previousFileName = "coach-checkpoint.prev.json"
  public static let currentVersion = 1
  /// A checkpoint older than this is not resumed (the system only offers recovery for a recent workout).
  public static let maxResumeAgeMs: Int64 = 6 * 3_600_000

  public var version: Int
  public var sessionId: String
  public var savedAtEpochMs: Int64
  /// Counts up with each write; the newer of two copies wins.
  public var seq: Int
  public var state: CoachSessionState

  public init(sessionId: String, savedAtEpochMs: Int64, seq: Int, state: CoachSessionState) {
    self.version = Self.currentVersion
    self.sessionId = sessionId
    self.savedAtEpochMs = savedAtEpochMs
    self.seq = seq
    self.state = state
  }

  public enum Loaded: Equatable {
    case none
    case valid(CoachCheckpoint, usedBackup: Bool)
    case unusable(String)
  }

  // MARK: Writing

  /// Atomic: the old file is kept as the `.prev` copy, then the new one is written to a temporary file and renamed in.
  public static func write(_ checkpoint: CoachCheckpoint, to folder: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = try enc.encode(checkpoint)
    let fm = FileManager.default
    let primary = folder.appendingPathComponent(fileName)
    let prev = folder.appendingPathComponent(previousFileName)
    // Only a readable primary is worth keeping: never replace a good backup with a corrupt file.
    if fm.fileExists(atPath: primary.path), decode(primary) != nil {
      try? fm.removeItem(at: prev)
      try? fm.copyItem(at: primary, to: prev)
    }
    // Write and fsync a temporary file, then rename it over the primary: a power loss keeps the old or the new, whole.
    let tmp = folder.appendingPathComponent(".coach-checkpoint.tmp")
    try? fm.removeItem(at: tmp)
    guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let h = try FileHandle(forWritingTo: tmp)
    do {
      try h.write(contentsOf: data)
      try h.synchronize()
      try h.close()
    } catch {
      try? h.close()
      try? fm.removeItem(at: tmp)
      throw error
    }
    if fm.fileExists(atPath: primary.path) {
      _ = try fm.replaceItemAt(primary, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: primary)
    }
  }

  /// Removes both copies (the session finished cleanly, or was turned into `coach.json`).
  public static func remove(from folder: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: folder.appendingPathComponent(fileName))
    try? fm.removeItem(at: folder.appendingPathComponent(previousFileName))
  }

  // MARK: Reading

  private static func decode(_ url: URL) -> CoachCheckpoint? {
    guard let data = try? Data(contentsOf: url), let cp = try? JSONDecoder().decode(CoachCheckpoint.self, from: data) else { return nil }
    guard cp.version == currentVersion, cp.state.isConsistent else { return nil }
    return cp
  }

  /// The newest readable, consistent checkpoint of the folder whose `sessionId` matches the folder name.
  public static func load(from folder: URL) -> Loaded {
    let fm = FileManager.default
    let primaryURL = folder.appendingPathComponent(fileName)
    let prevURL = folder.appendingPathComponent(previousFileName)
    let hasPrimary = fm.fileExists(atPath: primaryURL.path)
    let hasPrev = fm.fileExists(atPath: prevURL.path)
    guard hasPrimary || hasPrev else { return .none }
    let id = folder.lastPathComponent
    let primary = decode(primaryURL).flatMap { $0.sessionId == id ? $0 : nil }
    let prev = decode(prevURL).flatMap { $0.sessionId == id ? $0 : nil }
    switch (primary, prev) {
    case let (p?, q?): return p.seq >= q.seq ? .valid(p, usedBackup: false) : .valid(q, usedBackup: true)
    case let (p?, nil): return .valid(p, usedBackup: false)
    case let (nil, q?): return .valid(q, usedBackup: true)
    case (nil, nil): return .unusable("checkpoint unreadable or inconsistent")
    }
  }

  /// A session folder that can be resumed: unfinished, not already given a `coach.json`, with a fresh valid checkpoint.
  public struct Resumable: Equatable {
    public let folder: URL
    public let checkpoint: CoachCheckpoint
    public let usedBackup: Bool
  }

  /// The resumable session under `root`: only the NEWEST unfinished folder is ever considered. If it has no usable
  /// checkpoint the answer is nil, never an older folder: the live workout belongs to the newest session, and resuming
  /// into an older one would append one recording's data to another.
  public static func latestResumable(in root: URL, nowMs: Int64) -> Resumable? {
    guard let id = SessionFiles.unfinished(in: root).first else { return nil } // newest first
    let folder = root.appendingPathComponent(id)
    guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(CoachResult.fileName).path),
          case let .valid(cp, usedBackup) = load(from: folder), nowMs - cp.savedAtEpochMs <= maxResumeAgeMs else { return nil }
    return Resumable(folder: folder, checkpoint: cp, usedBackup: usedBackup)
  }

  // MARK: Giving up on a resume

  /// Writes `coach.json` (early) from the checkpoint when the folder has none, then removes the checkpoint.
  /// Returns whether a `coach.json` came out of it. An existing `coach.json` is never overwritten.
  @discardableResult
  public static func salvage(folder: URL, endedAtEpochMs: Int64) -> Bool {
    let fm = FileManager.default
    let coachURL = folder.appendingPathComponent(CoachResult.fileName)
    if fm.fileExists(atPath: coachURL.path) {
      remove(from: folder)
      return false
    }
    guard case let .valid(cp, _) = load(from: folder), let result = cp.state.makeResult(early: true, endedAtEpochMs: endedAtEpochMs) else {
      remove(from: folder)
      return false
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    // If the write fails the checkpoint stays, so a later attempt can still save the splits.
    guard let data = try? enc.encode(result), (try? data.write(to: coachURL, options: .atomic)) != nil else { return false }
    remove(from: folder)
    return true
  }
}

/// The `thermal` event detail: the values the gym-day report reads.
public enum ThermalLog {
  public static let kind = "thermal"

  public static func label(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }
}
