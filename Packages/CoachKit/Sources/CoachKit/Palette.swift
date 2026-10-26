import Foundation

/// Flat colours, one per activity, plus the text colour that passes 4.5:1 on each.
public enum Palette {
  public static let ink: UInt32 = 0x0B0B0F
  public static let bone: UInt32 = 0xF2EEE3

  public struct Swatch: Equatable {
    public let hex: UInt32
    public let textIsInk: Bool
    public var text: UInt32 { textIsInk ? Palette.ink : Palette.bone }
    public var contrast: Double { Palette.contrast(hex, text) }
  }

  public static func swatch(for a: Activity) -> Swatch {
    switch a {
    case .run, .transition: return Swatch(hex: 0xA9DDF2, textIsInk: true) // ice
    case .skierg: return Swatch(hex: 0x22C7E8, textIsInk: true) // cyan
    case .sledPush: return Swatch(hex: 0xDE45A8, textIsInk: true) // magenta
    case .sledPull: return Swatch(hex: 0x7C4DDB, textIsInk: false) // violet
    case .burpeeBroadJump: return Swatch(hex: 0xA6E22E, textIsInk: true) // lime
    case .row: return Swatch(hex: 0x14998A, textIsInk: true) // teal
    case .farmersCarry: return Swatch(hex: 0xF2A516, textIsInk: true) // amber
    case .sandbagLunges: return Swatch(hex: 0xF0644F, textIsInk: true) // coral
    case .wallBalls: return Swatch(hex: 0xE8337F, textIsInk: true) // hot pink
    case .rest: return Swatch(hex: 0x2A2A30, textIsInk: false)
    }
  }

  /// Heart-rate chip ramp, Z1 blue to Z5 red. Chip only; never a background.
  public static let zoneHex: [UInt32] = [0x4F8DF7, 0x3FBF7F, 0xF2C94C, 0xF2994A, 0xEB5757]

  public static func zone(bpm: Int, maxHR: Int = 185) -> Int {
    let p = Double(bpm) / Double(max(1, maxHR))
    switch p {
    case ..<0.6: return 1
    case ..<0.7: return 2
    case ..<0.8: return 3
    case ..<0.9: return 4
    default: return 5
    }
  }

  static func luminance(_ hex: UInt32) -> Double {
    func f(_ c: UInt32) -> Double {
      let v = Double(c) / 255
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * f((hex >> 16) & 255) + 0.7152 * f((hex >> 8) & 255) + 0.0722 * f(hex & 255)
  }

  /// WCAG contrast ratio.
  public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
