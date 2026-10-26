import Foundation

public struct CueEvent: Equatable {
  public enum Kind: String { case issued, finished, cancelled, timeout, failed, missed }
  public enum Mode: String { case speech, hapticOnly = "haptic_only" }

  public let epochMs: Int64
  public let cueId: Int
  public let kind: Kind
  public let mode: Mode
  public let headphones: Bool
  public let outputs: [String]
  public let phrase: String
  public let detail: String

  public init(epochMs: Int64, cueId: Int, kind: Kind, mode: Mode, headphones: Bool, outputs: [String], phrase: String, detail: String = "") {
    self.epochMs = epochMs
    self.cueId = cueId
    self.kind = kind
    self.mode = mode
    self.headphones = headphones
    self.outputs = outputs
    self.phrase = phrase
    self.detail = detail
  }

  public static let csvHeader = "epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail"

  public var csvLine: String {
    [
      "\(epochMs)", "\(cueId)", kind.rawValue, mode.rawValue, headphones ? "1" : "0",
      Csv.field(outputs.joined(separator: ";")), Csv.field(phrase), Csv.field(detail),
    ].joined(separator: ",")
  }
}

public struct CueStats: Equatable {
  public let issued: Int
  /// Spoken to a headphone route, the synthesizer reported finish, and the athlete did not mark it missed.
  public let delivered: Int
  public let hapticOnly: Int
  public let missed: Int
  public var deliveryPercent: Double { issued == 0 ? 0 : 100 * Double(delivered) / Double(issued) }
}

public enum CueLog {
  /// Delivery rule shared with `tools/m1_report.py`: a cue counts only if it was spoken to headphones,
  /// the synth reported finish, and nobody flagged it as not heard. Every issued cue is in the denominator.
  public static func stats(_ events: [CueEvent]) -> CueStats {
    let issued = events.filter { $0.kind == .issued }
    var delivered = 0, hapticOnly = 0, missed = 0
    for cue in issued {
      let mine = events.filter { $0.cueId == cue.cueId }
      let wasMissed = mine.contains { $0.kind == .missed }
      if wasMissed { missed += 1 }
      if cue.mode == .hapticOnly { hapticOnly += 1; continue }
      if cue.headphones, mine.contains(where: { $0.kind == .finished }), !wasMissed { delivered += 1 }
    }
    return CueStats(issued: issued.count, delivered: delivered, hapticOnly: hapticOnly, missed: missed)
  }
}

public enum RouteClassifier {
  /// `AVAudioSession.Port` raw values that mean the audio is not coming out of the watch speaker.
  public static let headphonePorts: Set<String> = ["BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE", "Headphones", "AirPlay"]

  public static func isHeadphones(portTypes: [String]) -> Bool {
    portTypes.contains { headphonePorts.contains($0) }
  }
}

public enum CuePhrases {
  public static let all = [
    "Jog in. Get your breath back on the run.",
    "Next station. Settle your breathing.",
    "Steady pace. Knee down.",
    "Twenty metres left.",
    "Keep your rhythm.",
    "Run. Do not walk the first two hundred.",
  ]

  public static func phrase(at index: Int) -> String { all[((index % all.count) + all.count) % all.count] }
}
