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
  /// Bold bone pill ("NEW BEST") that tells a best moment from a first one on the same colour.
  public let badge: String?
  /// Seconds the hero counts up to (nil: a plain string such as an em dash).
  public let heroSeconds: Int?
  public let heroIsClock: Bool
  /// Set for an early-ended session: stations done and in the plan. Share cards keep this in their kicker.
  public let partial: (done: Int, of: Int)?

  public static func == (l: MomentDisplay, r: MomentDisplay) -> Bool {
    l.kicker == r.kicker && l.hero == r.hero && l.line == r.line && l.badge == r.badge && l.flood == r.flood
      && l.partial?.done == r.partial?.done && l.partial?.of == r.partial?.of
  }

  /// - totalSeconds: the new session's total.
  /// - fadeSeconds: its run fade (nil with fewer than 2 runs).
  /// - previousDate: "24 Oct", for the new-best line.
  /// - sessionType: colours a least-fade moment (violet when unknown).
  /// - partial: stations done / in the plan when the session ended early. A partial never claims a fade baseline.
  public static func make(_ moment: Moment, totalSeconds: Int, fadeSeconds: Int?, previousDate: String? = nil, sessionType: SessionType? = nil,
                          partial: (done: Int, of: Int)? = nil) -> MomentDisplay {
    switch moment {
    case .first(let t):
      let kicker = "Your first \(t.title)" + (partial.map { " \u{00B7} \($0.done) of \($0.of) stations" } ?? "")
      let line: String
      if partial != nil {
        line = "Ended early. Finish one to set your baseline."
      } else {
        line = fadeSeconds.map { "Your fade baseline is \($0)\u{00A0}s." } ?? "That sets your baseline."
      }
      return MomentDisplay(kicker: kicker, hero: Fmt.clock(totalSeconds), line: line,
                           flood: PhoneTheme.sessionColor(t), text: PhoneTheme.sessionText(t), badge: nil,
                           heroSeconds: totalSeconds, heroIsClock: true, partial: partial)
    case .best(let t, let previousBest):
      let faster = Fmt.gap(previousBest - totalSeconds)
      let line = previousDate.map { "\u{25B2} \(faster) faster than \($0)." } ?? "\u{25B2} \(faster) faster than your last best."
      return MomentDisplay(kicker: t.title, hero: Fmt.clock(totalSeconds), line: line,
                           flood: PhoneTheme.sessionColor(t), text: PhoneTheme.sessionText(t), badge: "NEW BEST",
                           heroSeconds: totalSeconds, heroIsClock: true, partial: partial)
    case .leastFade(let previous):
      let t = sessionType ?? .fullSim
      let flood = PhoneTheme.sessionColor(t), text = PhoneTheme.sessionText(t)
      guard let fade = fadeSeconds else {
        return MomentDisplay(kicker: "Least fade yet", hero: "\u{2014}", line: "The runs are holding.", flood: flood, text: text,
                             badge: nil, heroSeconds: nil, heroIsClock: false, partial: partial)
      }
      return MomentDisplay(kicker: "Least fade yet", hero: "\(fade)\u{00A0}s",
                           line: "\(max(0, previous - fade))\u{00A0}s less than your best fade. The runs are holding.",
                           flood: flood, text: text, badge: nil, heroSeconds: fade, heroIsClock: false, partial: partial)
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
  let result: CoachResult?
  let animate: Bool
  var onNice: () -> Void
  var onShare: () -> Void

  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `animate: false` renders the settled end state (screenshots).
  public init(display: MomentDisplay, result: CoachResult? = nil, animate: Bool = true, onNice: @escaping () -> Void = {}, onShare: @escaping () -> Void = {}) {
    self.display = display
    self.result = result
    self.animate = animate
    self.onNice = onNice
    self.onShare = onShare
  }

  private var settled: Bool { !animate || shown }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let badge = display.badge {
        Text(badge).scaledFont(size: 13, weight: .heavy).tracking(1)
          .foregroundStyle(Theme.ink)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(Theme.bone, in: Capsule())
          .padding(.bottom, 12)
      }
      Text(display.kicker).scaledFont(size: 15, weight: .heavy).textCase(.uppercase).tracking(1)
      Group {
        if let secs = display.heroSeconds {
          CountingText(value: Double(settled ? secs : 0), clock: display.heroIsClock)
        } else {
          Text(display.hero)
        }
      }
      .scaledHero(size: 96).lineLimit(1).minimumScaleFactor(0.5)
      .padding(.top, 8)
      .accessibilityLabel(display.hero)
      .animation(animate && !reduceMotion ? .easeOut(duration: 1.1) : nil, value: shown)
      Text(display.line).scaledFont(size: 17, weight: .semibold).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
      if let result {
        ShareStrip(result: result)
          .padding(12)
          .background(PhoneTheme.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
          .padding(.top, 24)
      }
    }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Content is pinned at a fixed height (about 30% down) so every moment lines up whatever its line length.
      GeometryReader { geo in
        content.frame(maxWidth: .infinity, alignment: .leading).offset(y: geo.size.height * 0.26)
      }
      HStack(spacing: 12) {
        Button(action: onNice) {
          Text("Nice").scaledFont(size: 17, weight: .heavy, cap: 1.3).foregroundStyle(display.text)
            .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(display.text, lineWidth: 2))
        }
        Button(action: onShare) {
          Text("Share").scaledFont(size: 17, weight: .heavy, cap: 1.3).foregroundStyle(display.flood)
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
      guard animate, !shown else { return }
      shown = true
      #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
  }
}
