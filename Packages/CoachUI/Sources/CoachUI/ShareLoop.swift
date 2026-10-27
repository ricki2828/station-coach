import CoachKit
import Foundation
import SwiftUI

/// The 5 second share loop (storyboard in docs: C3). Frames are pure functions of `t`, so the encoder and the key-frame tests
/// render the same view. From `holdStart` to `holdEnd` the frame IS `ShareCardV2`, so the video ends on exactly the image people
/// already share and the still stays the fallback.
public enum ShareLoop {
  public static let duration: Double = 5.0
  public static let fps = 30
  public static var frameCount: Int { Int(duration * Double(fps)) }
  public static let holdStart: Double = 3.8
  public static let holdEnd: Double = 4.85
  public static let pixelSize = CGSize(width: 1080, height: 1350)

  /// True for the frames that are the still card, so an encoder can render one and reuse it.
  public static func isStill(_ t: Double) -> Bool { t >= holdStart && t <= holdEnd }

  static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
  static func progress(_ t: Double, _ start: Double, _ end: Double) -> Double { clamp((t - start) / (end - start)) }
  static func outCubic(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
  static func outQuart(_ u: Double) -> Double { 1 - pow(1 - u, 4) }
  /// Overshoots then settles: used for the badge pop.
  static func outBack(_ u: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
  }

  /// H:MM:SS for an hour or more, M:SS below, the same as `Fmt.clock`. `hour` forces H:MM:SS so a count-up never changes width.
  static func clock(_ seconds: Int, hour: Bool) -> String {
    let s = max(0, seconds)
    if hour || s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

/// One frame of the loop at time `t` seconds. 360 x 450 pt, render at scale 3 for 1080 x 1350.
public struct ShareLoopFrame: View {
  let result: CoachResult
  let moment: MomentDisplay?
  let dateText: String
  let t: Double

  public init(result: CoachResult, moment: MomentDisplay? = nil, dateText: String? = nil, t: Double) {
    self.result = result
    self.moment = moment
    self.dateText = dateText ?? ShareCardV2.date(result.startedAtEpochMs)
    self.t = t
  }

  // The copy below mirrors ShareCardV2's private kicker / hero line / insight. ShareLoopTests renders the last animated frame
  // against the still card, so a change in one that is not made in the other fails there.
  private var type: SessionType { result.plan.type }
  private var color: Color { moment?.flood ?? PhoneTheme.sessionColor(type) }
  private var textColor: Color { moment?.text ?? PhoneTheme.sessionText(type) }

  private var kicker: String {
    if let moment { return result.early && moment.partial == nil ? moment.kicker + " \u{00B7} \(result.completedStationCount) of \(result.plan.stationCount) stations" : moment.kicker }
    if result.early { return "\(type.title) \u{00B7} \(result.completedStationCount) of \(result.plan.stationCount) stations" }
    return type.title
  }

  private var heroLine: String? {
    if result.early { return "Ended early" }
    if let moment { return moment.line }
    let d = result.totalSeconds - result.plan.plannedSeconds
    return "\(Fmt.gap(d)) \(d <= 0 ? "under" : "over") target"
  }

  private var insight: String {
    guard result.early else { return InsightPicker.pick(result).headline }
    let done = result.rows.filter { $0.actualSeconds != nil }
    let actual = done.reduce(0) { $0 + ($1.actualSeconds ?? 0) }
    let planned = done.reduce(0) { $0 + $1.step.targetSeconds }
    let d = actual - planned
    let n = result.completedStationCount
    if abs(d) < 5 { return "On plan through \(n) stations." }
    return "\(Fmt.gap(d)) \(d < 0 ? "ahead of" : "behind") plan through \(n) stations."
  }

  /// The clock count-up position, 0...1, over 0.9 to 2.7 s (out-quart). The strip is revealed in step with it.
  private var clockProgress: Double { ShareLoop.outQuart(ShareLoop.progress(t, 0.9, 2.7)) }

  private var heroText: String {
    guard let moment else { return ShareLoop.clock(Int((Double(result.totalSeconds) * clockProgress).rounded(.down)), hour: result.totalSeconds >= 3600) }
    if let secs = moment.heroSeconds {
      let n = Int((Double(secs) * clockProgress).rounded(.down))
      return moment.heroIsClock ? ShareLoop.clock(n, hour: secs >= 3600) : (clockProgress >= 1 ? moment.hero : "\(n)\u{00A0}s")
    }
    return moment.hero
  }

  /// A moment hero with no count (an em dash) fades in with the card instead of counting.
  private var heroOpacity: Double { moment?.heroSeconds == nil && moment != nil ? ShareLoop.progress(t, 0.9, 1.3) : 1 }

  /// The station segment that lifts once while the insight sets: the one furthest over its plan.
  private var liftIndex: Int? {
    var best: (index: Int, over: Int)?
    for (i, row) in result.rows.enumerated() {
      guard !row.step.isRun, let actual = row.actualSeconds else { continue }
      let over: Int = actual - row.step.targetSeconds
      if best == nil || over > best!.over { best = (i, over) }
    }
    return best?.index
  }

  public var body: some View {
    if ShareLoop.isStill(t) {
      ShareCardV2(result: result, dateText: dateText, moment: moment)
    } else if t > ShareLoop.holdEnd {
      ShareCardV2(result: result, dateText: dateText, moment: moment)
        .opacity(1 - ShareLoop.progress(t, ShareLoop.holdEnd, ShareLoop.duration))
        .frame(width: ShareCardV2.size.width, height: ShareCardV2.size.height)
        .background(PhoneTheme.paper)
    } else {
      animated
    }
  }

  private var animated: some View {
    let wordmark = ShareLoop.progress(t, 0, 0.4)
    let rise = ShareLoop.outQuart(ShareLoop.progress(t, 0.4, 0.9))
    let line = ShareLoop.outCubic(ShareLoop.progress(t, 2.7, 3.2))
    let ins = ShareLoop.outCubic(ShareLoop.progress(t, 3.2, 3.8))
    let pop = ShareLoop.progress(t, 2.7, 2.95)
    let lift = ShareLoop.progress(t, 3.2, 3.7)
    return VStack(alignment: .leading, spacing: 0) {
      Wordmark(size: 18).opacity(wordmark)
      HeroCard(color: color, textColor: textColor) {
        VStack(alignment: .leading, spacing: 4) {
          if let badge = moment?.badge {
            Text(badge).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Theme.ink)
              .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.bone, in: Capsule())
              .scaleEffect(0.6 + 0.4 * ShareLoop.outBack(pop), anchor: .leading).opacity(pop > 0 ? 1 : 0)
          }
          Text(kicker).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1).lineLimit(1).minimumScaleFactor(0.7)
          Text(heroText).phoneHero(size: 110).lineLimit(1).minimumScaleFactor(0.4).opacity(heroOpacity)
          if let heroLine {
            Text(heroLine).font(.system(size: 17, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
              .opacity(line).offset(y: 12 * (1 - line))
          }
        }
      }
      .padding(.top, 16)
      .offset(y: 60 * (1 - rise))
      .opacity(rise)
      loopStrip(lift: lift).padding(.top, 20)
      Text(insight).font(.system(size: 18, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
        .fixedSize(horizontal: false, vertical: true).padding(.top, 18).opacity(ins)
      Spacer(minLength: 8)
      HStack {
        Text(dateText).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
        Spacer()
        Text(Brand.name).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
      }
      .foregroundStyle(PhoneTheme.muted)
      .opacity(wordmark)
    }
    .padding(20)
    .frame(width: ShareCardV2.size.width, height: ShareCardV2.size.height, alignment: .topLeading)
    .background(PhoneTheme.paper)
  }

  /// The real strip, revealed left to right at the clock's pace: the long stations visibly take longer. A faint track shows
  /// where it will fill. The named station lifts once as the insight sets.
  private func loopStrip(lift: Double) -> some View {
    let rise = ShareLoop.progress(t, 0.4, 0.9)
    return ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 2).fill(PhoneTheme.hairline.opacity(0.6 * (1 - clockProgress))).frame(height: ShareStrip.barHeight)
      GeometryReader { geo in
        ShareStrip(result: result).frame(width: geo.size.width)
          .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * clockProgress) }
      }
      if let i = liftIndex, lift > 0, lift < 1 { liftMark(index: i, lift: lift) }
    }
    .frame(height: ShareStrip.barHeight + 5 + 28, alignment: .top)
    .opacity(rise)
  }

  /// A small bar over the named segment that rises 6 pt and settles, drawn above the strip.
  private func liftMark(index: Int, lift: Double) -> some View {
    let weights = result.rows.map { Double(max(1, $0.actualSeconds ?? $0.step.targetSeconds)) }
    let total = weights.reduce(0, +)
    let before = weights.prefix(index).reduce(0, +)
    return GeometryReader { geo in
      let avail = geo.size.width - CGFloat(max(0, weights.count - 1)) * 2
      let x: CGFloat = avail * CGFloat(before / total) + CGFloat(index) * 2
      let w: CGFloat = max(2, avail * CGFloat(weights[index] / total))
      RoundedRectangle(cornerRadius: 2).fill(PhoneTheme.stationColor(result.rows[index].step.activity))
        .frame(width: w, height: ShareStrip.barHeight)
        .offset(x: x, y: CGFloat(-6.0 * sin(Double.pi * lift)))
    }
    .frame(height: ShareStrip.barHeight)
  }
}

// MARK: Share flow screens

public enum ShareFlowState: Equatable {
  case choosing
  case rendering(percent: Int)
  case failed
}

/// The sheet behind the session detail's Share button: video first, image first for a partial session (a half-empty animation reads as failure).
public struct ShareFlowSheet: View {
  let state: ShareFlowState
  let partial: Bool
  let onVideo: () -> Void
  let onImage: () -> Void
  let onCancel: () -> Void

  public init(state: ShareFlowState, partial: Bool, onVideo: @escaping () -> Void = {}, onImage: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
    self.state = state
    self.partial = partial
    self.onVideo = onVideo
    self.onImage = onImage
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch state {
      case .choosing:
        Text("Share").scaledStatement(size: 34).foregroundStyle(PhoneTheme.inkText)
        if partial {
          PrimaryButton("Image", action: onImage)
          SecondaryChoice(title: "Video \u{00B7} 5 s", action: onVideo)
        } else {
          PrimaryButton("Video \u{00B7} 5 s", action: onVideo)
          SecondaryChoice(title: "Image", action: onImage)
        }
        TextLinkButton("Cancel", action: onCancel)
      case .rendering(let percent):
        Text("Making your video\u{2026} \(percent)%").scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText)
        // Drawn, not ProgressView: ImageRenderer cannot render the UIKit-backed control.
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(PhoneTheme.hairline)
            Capsule().fill(PhoneTheme.inkText).frame(width: geo.size.width * Double(min(max(percent, 0), 100)) / 100)
          }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Making your video, \(percent / 25 * 25) percent")
        TextLinkButton("Cancel", action: onCancel)
      case .failed:
        Text("Couldn\u{2019}t make the video.").scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText)
        Text("Share the image instead?").scaledFont(17, .semibold).foregroundStyle(PhoneTheme.muted)
        PrimaryButton("Share image", action: onImage)
        TextLinkButton("Cancel", action: onCancel)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PhoneTheme.paper)
  }
}

private struct SecondaryChoice: View {
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).scaledFont(size: 17, weight: .heavy).foregroundStyle(PhoneTheme.inkText)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(PhoneTheme.inkText, lineWidth: 2))
    }
    .buttonStyle(.plain)
  }
}
