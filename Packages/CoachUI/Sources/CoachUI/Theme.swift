import CoachKit
import SwiftUI

/// Design tokens: the station palette (text colour chosen per swatch for 4.5:1), type sizes, spacing.
public enum Theme {
  public static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity)
  }

  public static let ink = color(Palette.ink)
  public static let bone = color(Palette.bone)
  /// "Behind plan". Never red.
  public static let amber = color(0xF2A516)
  public static let finishFlood = color(0xA6E22E)
  public static let earlyFlood = color(0xA9DDF2)

  public static func background(_ a: Activity) -> Color { color(Palette.swatch(for: a).hex) }
  public static func text(_ a: Activity) -> Color { color(Palette.swatch(for: a).text) }
  public static func zone(_ z: Int) -> Color { color(Palette.zoneHex[min(max(z, 1), 5) - 1]) }

  public enum Space {
    public static let unit: CGFloat = 4
    public static let watchEdge: CGFloat = 8
  }

  /// Watch type sizes. Numbers never go under `floor`.
  public enum Size {
    public static let dominant: CGFloat = 64
    public static let secondary: CGFloat = 36
    public static let floor: CGFloat = 36
    public static let label: CGFloat = 17
    public static let small: CGFloat = 15
  }

  /// Series 12 / 46 mm points.
  public static let watch46 = CGSize(width: 208, height: 248)
  public static let phone = CGSize(width: 390, height: 844)

  public static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
  public static func label(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

extension View {
  /// Condensed width where the OS has it; harmless otherwise.
  func condensed() -> some View { self.fontWidth(.condensed) }
}
