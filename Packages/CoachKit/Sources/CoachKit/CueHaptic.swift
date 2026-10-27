import Foundation

/// How the wrist can tell cues apart with the audio off. The watch app maps `motion` to a `WKHapticType`
/// and plays it `pulses` times; this file stays free of WatchKit so it is unit-tested on the host.
public enum HapticKind: CaseIterable, Equatable {
  case stationIntro, setDone, planBehind, planAhead, jogIn, finish

  public enum Motion: Equatable {
    /// A short click.
    case tap
    /// A rising pattern.
    case up
    /// A falling pattern.
    case down
    /// The system "start" pattern.
    case start
    /// The system "success" pattern.
    case success
  }

  public struct Signature: Hashable {
    public let motion: Motion
    public let pulses: Int
  }

  public var motion: Motion {
    switch self {
    case .stationIntro: return .start
    case .setDone: return .tap
    case .planBehind: return .down
    case .planAhead: return .up
    case .jogIn: return .up
    case .finish: return .success
    }
  }

  /// How many times the pattern is played, 0.3 s apart. The finish is the only one played three times.
  public var pulses: Int {
    switch self {
    case .stationIntro: return 2
    case .setDone, .planBehind, .jogIn: return 1
    case .planAhead: return 2
    case .finish: return 3
    }
  }

  public var signature: Signature { Signature(motion: motion, pulses: pulses) }
}

public enum CueHaptic {
  /// The haptic for each spoken cue. `midStation` and `planAndRun` carry the plan check, so their pattern follows the
  /// plan delta (`deltaSeconds`, positive = behind): falling when behind, rising twice when ahead, a plain tap when on plan
  /// (inside the 10 s the speech also calls on plan). The no-rep acknowledgement is a set-sized tap.
  public static func `for`(_ kind: CoachCueKind, deltaSeconds: Int) -> HapticKind {
    switch kind {
    case .stationIntro: return .stationIntro
    case .wallBallSet, .noRep: return .setDone
    case .midStation, .planAndRun:
      let b = DeltaMath.spokenBucket(deltaSeconds)
      return b > 0 ? .planBehind : (b < 0 ? .planAhead : .setDone)
    case .jogIn: return .jogIn
    case .finish: return .finish
    }
  }
}
