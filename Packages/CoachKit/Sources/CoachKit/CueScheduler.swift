import Foundation

/// Higher raw value wins when several cues wait.
public enum CoachCueKind: Int, Codable, Comparable {
  case jogIn = 0, wallBallSet = 1, midStation, planAndRun, stationIntro, finish
  /// "No rep noted": spoken in the rest straight away, or not at all.
  case noRep
  public static func < (a: CoachCueKind, b: CoachCueKind) -> Bool { a.rawValue < b.rawValue }
}

public struct CoachCue: Equatable {
  public let kind: CoachCueKind
  public let text: String
  public let createdAt: TimeInterval
  public init(kind: CoachCueKind, text: String, createdAt: TimeInterval) {
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
  }
}

/// At most one cue per `minGap` seconds, never while one is speaking, cues older than `maxAge` dropped.
/// The finish cue ignores the gap (it still waits for speech to end) and never goes stale. The no-rep cue ignores the
/// gap too but goes stale after `NoRepRest.cueMaxAgeSeconds`, so it is never said mid-set.
public struct CueScheduler {
  public static let minGap: TimeInterval = 20
  /// Longer than `minGap`, so a cue held back by the gap is not dropped for waiting out the gap.
  public static let maxAge: TimeInterval = 25

  private var lastSpokenAt: TimeInterval?
  private var pending: [CoachCue] = []
  public private(set) var dropped = 0

  public init() {}

  public var hasPending: Bool { !pending.isEmpty }

  public mutating func offer(_ cue: CoachCue) { pending.append(cue) }

  /// Forgets waiting cues of `kind` (a "Jog in" that is no use once the step has moved on). Not counted as dropped for age.
  public mutating func drop(_ kind: CoachCueKind) { pending.removeAll { $0.kind == kind } }

  /// The cue to say now, or nil. Call on a short timer and after each `offer`.
  public mutating func next(at t: TimeInterval, speaking: Bool) -> CoachCue? {
    let before = pending.count
    pending.removeAll {
      switch $0.kind {
      case .finish: return false
      case .noRep: return t - $0.createdAt > NoRepRest.cueMaxAgeSeconds
      default: return t - $0.createdAt > Self.maxAge
      }
    }
    dropped += before - pending.count
    guard !speaking, !pending.isEmpty else { return nil }
    guard let best = pending.max(by: { a, b in a.kind == b.kind ? a.createdAt > b.createdAt : a.kind < b.kind }) else { return nil }
    if let last = lastSpokenAt, t - last < Self.minGap, best.kind != .finish, best.kind != .noRep { return nil }
    pending.removeAll { $0 == best }
    lastSpokenAt = t
    return best
  }
}
