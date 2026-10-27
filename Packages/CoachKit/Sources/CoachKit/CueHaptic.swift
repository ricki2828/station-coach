import Foundation

/// How the wrist can tell cues apart with the audio off. The watch app maps `motion` to a `WKHapticType`
/// and plays it `pulses` times; this file stays free of WatchKit so it is unit-tested on the host.
public enum HapticKind: CaseIterable, Equatable {
  case stationIntro, setDone, planBehind, jogIn, finish

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
    case .jogIn: return .up
    case .finish: return .success
    }
  }

  /// How many times the pattern is played, 0.3 s apart. The finish is the only one played three times.
  public var pulses: Int {
    switch self {
    case .stationIntro: return 2
    case .setDone, .planBehind, .jogIn: return 1
    case .finish: return 3
    }
  }

  public var signature: Signature { Signature(motion: motion, pulses: pulses) }
}

public enum CueHaptic {
  /// The haptic for each spoken cue. `midStation` and `planAndRun` carry the plan check, so they share the plan
  /// pattern; the no-rep acknowledgement is a set-sized tap. Five patterns for seven kinds.
  public static func `for`(_ kind: CoachCueKind) -> HapticKind {
    switch kind {
    case .stationIntro: return .stationIntro
    case .wallBallSet, .noRep: return .setDone
    case .midStation, .planAndRun: return .planBehind
    case .jogIn: return .jogIn
    case .finish: return .finish
    }
  }
}
