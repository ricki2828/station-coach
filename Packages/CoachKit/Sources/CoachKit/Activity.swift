import Foundation

/// The ten things the recorder labels, plus "rest". Raw values are the ids used in `labels.csv`.
public enum Activity: String, CaseIterable, Codable, Sendable, Identifiable {
  case run
  case transition
  case skierg
  case sledPush = "sled_push"
  case sledPull = "sled_pull"
  case burpeeBroadJump = "burpee_broad_jump"
  case row
  case farmersCarry = "farmers_carry"
  case sandbagLunges = "sandbag_lunges"
  case wallBalls = "wall_balls"
  case rest

  public var id: String { rawValue }

  /// Short label for a watch button.
  public var buttonTitle: String {
    switch self {
    case .run: return "Run"
    case .transition: return "Changeover"
    case .skierg: return "SkiErg"
    case .sledPush: return "Sled push"
    case .sledPull: return "Sled pull"
    case .burpeeBroadJump: return "Burpee BJ"
    case .row: return "Row"
    case .farmersCarry: return "Carry"
    case .sandbagLunges: return "Lunges"
    case .wallBalls: return "Wall balls"
    case .rest: return "Rest"
    }
  }

  /// The ten activities the detector must learn (everything except `rest`).
  public static var coached: [Activity] { allCases.filter { $0 != .rest } }
}
