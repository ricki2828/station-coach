import SwiftUI

/// System font that grows with Dynamic Type, with a cap so heroes and buttons cannot break their layout.
private struct ScaledFontModifier: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let weight: Font.Weight
  let cap: CGFloat
  let base: CGFloat
  let condensedNumber: Bool

  init(size: CGFloat, weight: Font.Weight, cap: CGFloat, relativeTo: Font.TextStyle, number: Bool) {
    self._size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    self.weight = weight
    self.cap = cap
    self.base = size
    self.condensedNumber = number
  }

  func body(content: Content) -> some View {
    let s = min(size, base * cap)
    if condensedNumber {
      content.font(Theme.number(s)).fontWidth(.condensed).monospacedDigit()
    } else {
      content.font(.system(size: s, weight: weight))
    }
  }
}

extension View {
  func scaledFont(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body, cap: CGFloat = 1.6) -> some View {
    modifier(ScaledFontModifier(size: size, weight: weight, cap: cap, relativeTo: relativeTo, number: false))
  }

  /// Condensed number face (the phone hero), scaling up to `cap` times its base size.
  func scaledHero(size: CGFloat, cap: CGFloat = 1.15) -> some View {
    modifier(ScaledFontModifier(size: size, weight: .heavy, cap: cap, relativeTo: .largeTitle, number: true))
  }

  /// Condensed heavy caps statement, scaling up to `cap` times its base size.
  func scaledStatement(size: CGFloat, cap: CGFloat = 1.2) -> some View {
    scaledFont(size: size, weight: .heavy, relativeTo: .largeTitle, cap: cap)
      .fontWidth(.condensed).textCase(.uppercase).tracking(-0.5)
  }
}
