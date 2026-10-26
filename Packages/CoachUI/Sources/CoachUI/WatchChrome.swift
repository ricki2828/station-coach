import SwiftUI

/// What the iOS test host does not draw: the 46 mm display's rounded corners and the system clock, plus
/// the top safe area the clock leaves. Wraps a watch screen in the snapshots so clipping shows in the PNGs.
/// The numbers are estimates for a 46 mm watch, not measurements.
public struct WatchChrome<Content: View>: View {
  public static var cornerRadius: CGFloat { 44 }
  public static var topInset: CGFloat { 24 }

  let content: Content
  let size: CGSize

  public init(size: CGSize = Theme.watch46, @ViewBuilder _ content: () -> Content) {
    self.size = size
    self.content = content()
  }

  public var body: some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.topInset) }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
      .overlay(alignment: .topTrailing) {
        Text("10:09").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(Color.black.opacity(0.55), in: Capsule())
          .padding(.top, 3).padding(.trailing, 16)
      }
      .background(Color.black)
  }
}
