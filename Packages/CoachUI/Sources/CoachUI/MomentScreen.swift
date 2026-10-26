import CoachKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The words, number and colour for one phone moment. Built from a `Moment` plus the figures the moment itself lacks.
public struct MomentDisplay: Equatable {
  public let kicker: String
  public let hero: String
  public let line: String
  public let flood: Color
  public let text: Color
  /// Seconds the hero counts up to (nil: a plain string).
  public let heroSeconds: Int?
  public let heroIsClock: Bool

  /// - totalSeconds: the new session's total.
  /// - fadeSeconds: its run fade (nil with fewer than 2 runs).
  /// - previousDate: "24 Oct", for the new-best line.
  public static func make(_ moment: Moment, totalSeconds: Int, fadeSeconds: Int?, previousDate: String? = nil) -> MomentDisplay {
    switch moment {
    case .first(let t):
      let line = fadeSeconds.map { "Your fade baseline is \($0)\u{00A0}s." } ?? "That sets your baseline."
      return MomentDisplay(kicker: "Your first \(t.title)", hero: Fmt.clock(totalSeconds), line: line,
                           flood: PhoneTheme.sessionColor(t), text: PhoneTheme.sessionText(t), heroSeconds: totalSeconds, heroIsClock: true)
    case .best(let t, let previousBest):
      let faster = Fmt.gap(previousBest - totalSeconds)
      let line = previousDate.map { "\(faster) faster than \($0)." } ?? "\(faster) faster than your last best."
      return MomentDisplay(kicker: "New \(t.title) best", hero: Fmt.clock(totalSeconds), line: line,
                           flood: PhoneTheme.best, text: PhoneTheme.bestText, heroSeconds: totalSeconds, heroIsClock: true)
    case .leastFade(let previous):
      let fade = fadeSeconds ?? 0
      return MomentDisplay(kicker: "Least fade yet", hero: "\(fade)\u{00A0}s",
                           line: "\(max(0, previous - fade))\u{00A0}s less than your best before. The runs are holding.",
                           flood: PhoneTheme.sessionColor(.fullSim), text: PhoneTheme.sessionText(.fullSim), heroSeconds: fade, heroIsClock: false)
    }
  }
}

/// A number that counts up from zero. Animates through `animatableData`, so any `withAnimation` drives it.
private struct CountingText: View, Animatable {
  var value: Double
  let clock: Bool
  var animatableData: Double {
    get { value }
    set { value = newValue }
  }

  var body: some View {
    let n = Int(value.rounded())
    Text(clock ? Fmt.clock(n) : "\(n)\u{00A0}s")
  }
}

/// Full-flood moment: kicker, giant number, one line, Nice / Share. Rare by design.
public struct MomentScreen: View {
  let display: MomentDisplay
  let animate: Bool
  var onNice: () -> Void
  var onShare: () -> Void

  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `animate: false` renders the settled end state (screenshots).
  public init(display: MomentDisplay, animate: Bool = true, onNice: @escaping () -> Void = {}, onShare: @escaping () -> Void = {}) {
    self.display = display
    self.animate = animate
    self.onNice = onNice
    self.onShare = onShare
  }

  private var settled: Bool { !animate || shown }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer(minLength: 0)
      Text(display.kicker).font(.system(size: 15, weight: .heavy)).textCase(.uppercase).tracking(1)
      CountingText(value: Double(settled ? (display.heroSeconds ?? 0) : 0), clock: display.heroIsClock)
        .phoneHero(size: 96).lineLimit(1).minimumScaleFactor(0.5)
        .padding(.top, 8)
        .accessibilityLabel(display.hero)
        .animation(animate && !reduceMotion ? .easeOut(duration: 1.1) : nil, value: shown)
      Text(display.line).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
      Spacer(minLength: 0)
      HStack(spacing: 12) {
        Button(action: onNice) {
          Text("Nice").font(.system(size: 17, weight: .heavy)).foregroundStyle(display.text)
            .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(display.text, lineWidth: 2))
        }
        Button(action: onShare) {
          Text("Share").font(.system(size: 17, weight: .heavy)).foregroundStyle(display.flood)
            .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
            .background(display.text, in: RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius))
        }
      }
      .buttonStyle(.plain)
    }
    .foregroundStyle(display.text)
    .padding(.horizontal, 28)
    .padding(.top, 48)
    .padding(.bottom, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(display.flood.ignoresSafeArea())
    .opacity(animate && reduceMotion && !shown ? 0 : 1)
    .animation(animate && reduceMotion ? .easeIn(duration: 0.4) : nil, value: shown)
    .onAppear {
      guard animate else { return }
      shown = true
      #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
  }
}
