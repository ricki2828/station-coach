import SwiftUI

/// Phone text that follows Dynamic Type. `PhoneTheme.Face` sizes are fixed; these scale from the same base sizes,
/// and `maxScale` caps big numbers so a hero figure cannot outgrow its card.
struct ScaledFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  private let base: CGFloat
  private let weight: Font.Weight
  private let maxScale: CGFloat
  private let condensed: Bool
  private let digits: Bool

  init(size: CGFloat, weight: Font.Weight, maxScale: CGFloat, condensed: Bool, digits: Bool) {
    _size = ScaledMetric(wrappedValue: size, relativeTo: Self.style(for: size))
    base = size
    self.weight = weight
    self.maxScale = maxScale
    self.condensed = condensed
    self.digits = digits
  }

  static func style(for size: CGFloat) -> Font.TextStyle {
    switch size {
    case ..<14: return .caption
    case ..<22: return .body
    case ..<40: return .title2
    default: return .largeTitle
    }
  }

  @ViewBuilder func body(content: Content) -> some View {
    let f = content.font(.system(size: min(size, base * maxScale), weight: weight))
    if condensed && digits { f.fontWidth(.condensed).monospacedDigit() } else if condensed { f.fontWidth(.condensed) } else { f }
  }
}

extension View {
  func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .regular, maxScale: CGFloat = 1.6) -> some View {
    modifier(ScaledFont(size: size, weight: weight, maxScale: maxScale, condensed: false, digits: false))
  }

  /// Hero figure: condensed digits, capped at 1.2x so it fits the card.
  func scaledHero(size: CGFloat = PhoneTheme.Face.heroSize) -> some View {
    modifier(ScaledFont(size: size, weight: .heavy, maxScale: 1.2, condensed: true, digits: true))
  }

  func scaledStat() -> some View {
    modifier(ScaledFont(size: PhoneTheme.Face.statSize, weight: .heavy, maxScale: 1.4, condensed: true, digits: true))
  }

  /// Condensed heavy caps headline, capped at 1.25x.
  func scaledStatement(size: CGFloat = PhoneTheme.Face.statementSize) -> some View {
    modifier(ScaledFont(size: size, weight: .heavy, maxScale: 1.25, condensed: true, digits: false))
      .textCase(.uppercase).tracking(-0.5)
  }

  func scaledKicker(color: Color = PhoneTheme.muted) -> some View {
    modifier(ScaledFont(size: PhoneTheme.Face.kickerSize, weight: .heavy, maxScale: 1.6, condensed: false, digits: false))
      .textCase(.uppercase).tracking(1).foregroundStyle(color)
  }
}
