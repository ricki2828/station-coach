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
      .environment(\.watchCompact, size.height <= watchCompactMaxHeight)
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

/// The Always-On (wrist down) look. The system sets `isLuminanceReduced`; this key forces it for snapshots, where
/// the iOS test host never reduces luminance.
struct WatchDimmedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var watchDimmed: Bool {
    get { self[WatchDimmedKey.self] }
    set { self[WatchDimmedKey.self] = newValue }
  }
}

/// The five watch case sizes the screens are checked at, in points.
public enum WatchSizes {
  public struct Size: Equatable {
    public let mm: Int
    public let points: CGSize
  }

  public static let all: [Size] = [
    Size(mm: 40, points: CGSize(width: 162, height: 197)),
    Size(mm: 41, points: CGSize(width: 176, height: 215)),
    Size(mm: 42, points: CGSize(width: 187, height: 223)),
    Size(mm: 45, points: CGSize(width: 198, height: 242)),
    Size(mm: 46, points: CGSize(width: 208, height: 248)),
  ]
}
