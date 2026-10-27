import CoachKit
import SwiftUI

/// Name shown on the wordmark, the display names and card footers. One constant so a rename is one edit.
public enum Brand {
  public static let name = "Station Coach"
}

/// Light everyday tokens for the phone. Watch tokens stay in `Theme`; the station `Palette` is shared.
/// Colour arrives at first glance (session hero cards, station strips), drama is kept for moments.
public enum PhoneTheme {
  // Surfaces and text
  public static let paperHex: UInt32 = 0xF8F6F1
  public static let cardHex: UInt32 = 0xFFFFFF
  public static let hairlineHex: UInt32 = 0xE4DFD3
  public static let mutedHex: UInt32 = 0x5E5B54
  /// Amber F2A516 fails on paper (and the first pick B26B00 was 3.9:1), so "over target" words use this darker one. Never red.
  public static let amberTextHex: UInt32 = 0x9A5B00
  public static let bestHex: UInt32 = 0x22C7E8

  public static let paper = Theme.color(paperHex)
  public static let card = Theme.color(cardHex)
  public static let hairline = Theme.color(hairlineHex)
  public static let inkText = Theme.ink
  public static let muted = Theme.color(mutedHex)
  public static let amberText = Theme.color(amberTextHex)
  /// New-best moments only.
  public static let best = Theme.color(bestHex)
  public static let bestText = Theme.ink

  public static let cardRadius: CGFloat = 20
  public static let buttonHeight: CGFloat = 56
  public static let buttonRadius: CGFloat = 16

  // Session colours: full = violet, half = cyan, wall-ball focus = pink, race day = ink.
  public static func sessionHex(_ t: SessionType) -> UInt32 {
    switch t {
    case .fullSim: return 0x7C4DDB
    case .halfSim: return 0x22C7E8
    case .wallBallFocus: return 0xE8337F
    // Race day is the one dark card: the nine flat colours are all taken by stations.
    case .raceDay: return Palette.ink
    }
  }

  public static func sessionTextHex(_ t: SessionType) -> UInt32 {
    (t == .fullSim || t == .raceDay) ? Palette.bone : Palette.ink
  }

  public static func sessionColor(_ t: SessionType) -> Color { Theme.color(sessionHex(t)) }
  public static func sessionText(_ t: SessionType) -> Color { Theme.color(sessionTextHex(t)) }

  /// Table-row chip tint: the station swatch at 0.16 opacity on paper.
  public static func stationTint(_ a: Activity) -> Color { Theme.color(Palette.swatch(for: a).hex, opacity: 0.16) }
  public static func stationColor(_ a: Activity) -> Color { Theme.color(Palette.swatch(for: a).hex) }

  /// Phone type. Every number is at least 28 pt.
  public enum Face {
    public static let statementSize: CGFloat = 44
    public static let heroSize: CGFloat = 72
    public static let statSize: CGFloat = 28
    public static let kickerSize: CGFloat = 13

    public static let statement = Font.system(size: statementSize, weight: .heavy)
    public static let hero = Theme.number(heroSize)
    public static let stat = Theme.number(statSize)
    public static let kicker = Font.system(size: kickerSize, weight: .heavy)
  }
}

public extension View {
  /// Hero headline: condensed heavy caps.
  func phoneStatement(size: CGFloat = PhoneTheme.Face.statementSize) -> some View {
    self.font(.system(size: size, weight: .heavy)).fontWidth(.condensed).textCase(.uppercase).tracking(-0.5)
  }

  func phoneHero(size: CGFloat = PhoneTheme.Face.heroSize) -> some View {
    self.font(Theme.number(size)).fontWidth(.condensed).monospacedDigit()
  }

  func phoneStat() -> some View {
    self.font(PhoneTheme.Face.stat).fontWidth(.condensed).monospacedDigit()
  }

  /// Card label: 13 pt heavy caps, +1 tracking.
  func phoneKicker(color: Color = PhoneTheme.muted) -> some View {
    self.font(PhoneTheme.Face.kicker).textCase(.uppercase).tracking(1).foregroundStyle(color)
  }
}

// MARK: - Components

/// Everyday card: white, 1 pt hairline, radius 20.
public struct PhoneCard<Content: View>: View {
  let content: Content
  public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
  public var body: some View {
    content
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(PhoneTheme.card, in: RoundedRectangle(cornerRadius: PhoneTheme.cardRadius))
      .overlay(RoundedRectangle(cornerRadius: PhoneTheme.cardRadius).stroke(PhoneTheme.hairline, lineWidth: 1))
  }
}

/// Rounded colour card; pass the matching text colour so contents stay legible.
public struct HeroCard<Content: View>: View {
  let color: Color
  let textColor: Color
  let content: Content
  public init(color: Color, textColor: Color = Theme.ink, @ViewBuilder _ content: () -> Content) {
    self.color = color
    self.textColor = textColor
    self.content = content()
  }

  public init(type: SessionType, @ViewBuilder _ content: () -> Content) {
    self.init(color: PhoneTheme.sessionColor(type), textColor: PhoneTheme.sessionText(type), content)
  }

  public var body: some View {
    content
      .foregroundStyle(textColor)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color, in: RoundedRectangle(cornerRadius: PhoneTheme.cardRadius))
  }
}

public struct StatTile: View {
  let kicker: String
  let value: String
  let caption: String?
  public init(kicker: String, value: String, caption: String? = nil) {
    self.kicker = kicker
    self.value = value
    self.caption = caption
  }

  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(kicker).phoneKicker()
        Text(value).phoneStat().foregroundStyle(PhoneTheme.inkText)
        if let caption { Text(caption).font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.muted) }
      }
    }
  }
}

public struct SessionChip: View {
  let type: SessionType
  public init(_ type: SessionType) { self.type = type }
  public var body: some View {
    Text(type.title)
      .font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
      .lineLimit(1).minimumScaleFactor(0.7)
      .foregroundStyle(PhoneTheme.sessionText(type))
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(PhoneTheme.sessionColor(type), in: Capsule())
  }
}

/// One segment per plan step, proportional to actual time (target time for steps not done, drawn as a hairline outline).
/// Runs are ice; stations take their swatch. `labelled` adds the eight station initials underneath.
public struct StationStrip: View {
  let result: CoachResult
  let labelled: Bool
  let height: CGFloat
  public init(result: CoachResult, labelled: Bool = false, height: CGFloat = 8) {
    self.result = result
    self.labelled = labelled
    self.height = height
  }

  private struct Seg: Identifiable {
    let id: Int
    let weight: Double
    let activity: Activity
    let done: Bool
    let initial: String?
  }

  static func shortName(_ a: Activity) -> String {
    switch a {
    case .skierg: return "Ski"
    case .sledPush: return "Push"
    case .sledPull: return "Pull"
    case .burpeeBroadJump: return "BBJ"
    case .row: return "Row"
    case .farmersCarry: return "Carry"
    case .sandbagLunges: return "Lunge"
    case .wallBalls: return "WB"
    default: return "Run"
    }
  }

  private var segments: [Seg] {
    result.rows.map { r in
      let done = r.actualSeconds != nil
      let w = Double(max(1, r.actualSeconds ?? r.step.targetSeconds))
      let initial = r.step.isRun ? nil : Self.shortName(r.step.activity)
      return Seg(id: r.step.index, weight: w, activity: r.step.activity, done: done, initial: initial)
    }
  }

  public var body: some View {
    let segs = segments
    let total = segs.reduce(0) { $0 + $1.weight }
    VStack(spacing: 6) {
      GeometryReader { geo in
        let gaps = CGFloat(max(0, segs.count - 1)) * 2
        let avail = geo.size.width - gaps
        HStack(spacing: 2) {
          ForEach(segs) { s in
            let w = max(2, avail * s.weight / total)
            if s.done {
              RoundedRectangle(cornerRadius: 2).fill(PhoneTheme.stationColor(s.activity)).frame(width: w)
            } else {
              RoundedRectangle(cornerRadius: 2).stroke(PhoneTheme.hairline, lineWidth: 1).frame(width: w)
            }
          }
        }
      }
      .frame(height: height)
      if labelled {
        // Short names centred under each station cell (runs stay unlabelled); they may overhang a narrow cell
        // but stay clear of each other because a run always sits between two stations.
        GeometryReader { geo in
          let gaps = CGFloat(max(0, segs.count - 1)) * 2
          let avail = geo.size.width - gaps
          let starts = segs.indices.map { i in segs[..<i].reduce(CGFloat(0)) { $0 + avail * $1.weight / total + 2 } }
          ForEach(segs) { s in
            if let name = s.initial {
              let i = segs.firstIndex { $0.id == s.id } ?? 0
              let w = avail * s.weight / total
              Text(name)
                .font(.system(size: 10, weight: .heavy)).textCase(.uppercase)
                .foregroundStyle(s.done ? PhoneTheme.inkText : PhoneTheme.muted)
                .fixedSize()
                .position(x: min(max(starts[i] + w / 2, 14), geo.size.width - 14), y: 7)
            }
          }
        }
        .frame(height: 14)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Station strip, \(result.completedStationCount) of \(result.plan.stationCount) stations done")
  }
}

/// Bars with the value on top and a caption underneath. Taller = bigger value. Tap-for-value is a screen concern.
public struct RecentBars: View {
  let values: [Int]
  let colors: [Color]
  let caption: String
  let unit: String
  let barMax: CGFloat
  public init(values: [Int], colors: [Color], caption: String, unit: String = " s", barMax: CGFloat = 96) {
    self.values = values
    self.colors = colors
    self.caption = caption
    self.unit = unit
    self.barMax = barMax
  }

  public var body: some View {
    let top = CGFloat(max(1, values.max() ?? 1))
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .bottom, spacing: 8) {
        ForEach(Array(values.enumerated()), id: \.offset) { i, v in
          VStack(spacing: 4) {
            Text("\(v)\(unit)").font(.system(size: 13, weight: .bold)).foregroundStyle(PhoneTheme.inkText).lineLimit(1).minimumScaleFactor(0.8)
            RoundedRectangle(cornerRadius: 6)
              .fill(i < colors.count ? colors[i] : PhoneTheme.hairline)
              .frame(height: max(8, barMax * CGFloat(max(0, v)) / top))
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: barMax + 24, alignment: .bottom)
      Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
    }
  }
}

public struct PrimaryButton: View {
  let title: String
  let action: () -> Void
  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .background(PhoneTheme.inkText, in: RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius))
    }
    .buttonStyle(.plain)
  }
}

public struct SecondaryButton: View {
  let title: String
  let action: () -> Void
  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 17, weight: .heavy)).foregroundStyle(PhoneTheme.inkText)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(PhoneTheme.inkText, lineWidth: 2))
    }
    .buttonStyle(.plain)
  }
}

/// 15 pt semibold underlined link-style button.
public struct TextLinkButton: View {
  let title: String
  let action: () -> Void
  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 15, weight: .semibold)).underline().foregroundStyle(PhoneTheme.inkText)
        .frame(minHeight: 44)
    }
    .buttonStyle(.plain)
  }
}

/// Brand name in the statement face over a 4 pt, 9-segment station bar (the strip is the logo).
public struct Wordmark: View {
  let size: CGFloat
  public init(size: CGFloat = 22) { self.size = size }

  public static let barActivities: [Activity] = [.run, .skierg, .sledPush, .sledPull, .burpeeBroadJump, .row, .farmersCarry, .sandbagLunges, .wallBalls]

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(Brand.name).phoneStatement(size: size).foregroundStyle(PhoneTheme.inkText).fixedSize()
      HStack(spacing: 0) {
        ForEach(Array(Self.barActivities.enumerated()), id: \.offset) { _, a in
          Rectangle().fill(PhoneTheme.stationColor(a))
        }
      }
      .frame(height: 4)
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Brand.name)
  }
}
