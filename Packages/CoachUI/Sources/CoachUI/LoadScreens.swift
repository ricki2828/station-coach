import CoachKit
import SwiftUI

// MARK: - Bars

/// One slice of a bar: load carried by one session type.
public struct LoadSegment: Equatable {
  public let type: SessionType
  public let load: Double
  public init(type: SessionType, load: Double) {
    self.type = type
    self.load = load
  }
}

/// One bar of the load chart. `soFar` draws a dashed outline (period not finished); `flagged` an amber outline (big jump).
public struct LoadBar: Equatable, Identifiable {
  public let id: Int
  public let label: String
  public let segments: [LoadSegment]
  public let isCurrent: Bool
  public let soFar: Bool
  public let flagged: Bool
  public let future: Bool

  public init(id: Int, label: String, segments: [LoadSegment], isCurrent: Bool = false, soFar: Bool = false, flagged: Bool = false, future: Bool = false) {
    self.id = id
    self.label = label
    self.segments = segments
    self.isCurrent = isCurrent
    self.soFar = soFar
    self.flagged = flagged
    self.future = future
  }

  public var total: Double { segments.reduce(0) { $0 + $1.load } }

  /// Full sim at the bottom, then half sim, then wall-ball focus.
  static func segments(_ p: LoadPeriod) -> [LoadSegment] {
    [SessionType.fullSim, .halfSim, .wallBallFocus].compactMap { t in
      let v = p.loadByType[t] ?? 0
      return v > 0 ? LoadSegment(type: t, load: v) : nil
    }
  }

  static func label(_ date: Date, calendar: Calendar, format: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = format
    return f.string(from: date).uppercased()
  }

  /// Newest last. A period still in progress (`isCurrent`) is drawn dashed and tagged "So far".
  public static func bars(_ periods: [LoadPeriod], calendar: Calendar, format: String = "d MMM", flagCurrent: Bool = false) -> [LoadBar] {
    periods.enumerated().map { i, p in
      let last = i == periods.count - 1
      return LoadBar(id: i, label: label(p.start, calendar: calendar, format: format), segments: segments(p), isCurrent: p.isCurrent,
                     soFar: p.isCurrent, flagged: last && flagCurrent && !p.isCurrent)
    }
  }
}

/// Load bars stacked by session type, with an optional dashed "usual" line. Taller is more load.
public struct LoadBars: View {
  let bars: [LoadBar]
  let usual: Int?
  let caption: String?
  let barMax: CGFloat
  let showValues: Bool
  let showLabels: Bool
  let compactLabels: Bool

  public init(bars: [LoadBar], usual: Int? = nil, caption: String? = "Taller is more load", barMax: CGFloat = 120,
              showValues: Bool = true, showLabels: Bool = true, compactLabels: Bool = false) {
    self.bars = bars
    self.usual = usual
    self.caption = caption
    self.barMax = barMax
    self.showValues = showValues
    self.showLabels = showLabels
    self.compactLabels = compactLabels
  }

  private var showSoFarRow: Bool { bars.contains { $0.soFar } }
  private var labelsBelow: CGFloat { showLabels ? 22 + (showSoFarRow ? 12 : 0) : 0 }
  private var top: Double { max(1, bars.map(\.total).max() ?? 1, Double(usual ?? 0)) }
  private func height(_ v: Double) -> CGFloat { barMax * CGFloat(v / top) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let usual { usualKey(usual) }
      ZStack(alignment: .bottomLeading) {
        HStack(alignment: .bottom, spacing: bars.count > 8 ? 4 : 8) {
          ForEach(bars) { bar in column(bar) }
        }
        .frame(maxWidth: .infinity)
        if let usual {
          usualLine(usual)
        }
      }
      .frame(height: barMax + (showValues ? 22 : 0) + labelsBelow, alignment: .bottom)
      if let caption {
        Text(caption).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
  }

  private var accessibility: String {
    let parts = bars.filter { !$0.future }.map { "\($0.label)\($0.soFar ? " so far" : "") \(LoadWords.number(Int($0.total.rounded())))" }
    return "Load by period. " + parts.joined(separator: ", ") + (usual.map { ". Usual \(LoadWords.number($0))" } ?? "")
  }

  @ViewBuilder private func column(_ bar: LoadBar) -> some View {
    VStack(spacing: 4) {
      if showValues {
        Text(bar.future || bar.total <= 0 ? " " : LoadWords.number(Int(bar.total.rounded())))
          .font(.system(size: 13, weight: .bold)).foregroundStyle(PhoneTheme.inkText)
          .lineLimit(1).minimumScaleFactor(0.6)
          .frame(height: 18)
      }
      barBody(bar)
      if showLabels {
        VStack(spacing: 0) {
          Text(bar.label)
            .font(.system(size: compactLabels ? 11 : 13, weight: bar.isCurrent ? .heavy : .semibold))
            .foregroundStyle(bar.isCurrent ? PhoneTheme.inkText : PhoneTheme.muted)
            .lineLimit(1)
            .frame(height: 18)
          Text(bar.soFar ? "SO FAR" : " ").font(.system(size: 10, weight: .heavy)).tracking(0.5)
            .foregroundStyle(PhoneTheme.inkText).lineLimit(1).fixedSize()
            .frame(height: showSoFarRow ? 12 : 0).opacity(showSoFarRow ? 1 : 0)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private func barBody(_ bar: LoadBar) -> some View {
    let h = max(2, height(bar.total))
    ZStack(alignment: .bottom) {
      if bar.total <= 0 {
        RoundedRectangle(cornerRadius: 1).fill(PhoneTheme.hairline).frame(height: 2)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(bar.segments.reversed().enumerated()), id: \.offset) { _, s in
            Rectangle().fill(PhoneTheme.sessionColor(s.type)).frame(height: max(1, height(s.load)))
          }
        }
        .frame(height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        if bar.soFar {
          RoundedRectangle(cornerRadius: 6).stroke(PhoneTheme.inkText, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(height: h)
        }
        if bar.flagged {
          RoundedRectangle(cornerRadius: 6).stroke(PhoneTheme.amberText, lineWidth: 2).frame(height: h)
        }
      }
    }
    .frame(height: barMax, alignment: .bottom)
  }

  private func usualLine(_ usual: Int) -> some View {
    DashedRule().stroke(PhoneTheme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      .frame(height: 1)
      .padding(.bottom, labelsBelow + height(Double(usual)))
      .allowsHitTesting(false)
  }

  private func usualKey(_ usual: Int) -> some View {
    HStack(spacing: 8) {
      DashedRule().stroke(PhoneTheme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).frame(width: 28, height: 1)
      Text("Usual \(LoadWords.number(usual))").scaledFont(13, .bold).foregroundStyle(PhoneTheme.muted)
    }
  }
}

private struct DashedRule: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.midY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return p
  }
}

// MARK: - Week card (Home)

/// Home card: this week so far, a 6-bar mini chart. Tapping opens the last complete week's summary.
public struct WeekCard: View {
  let period: LoadPeriod
  let bars: [LoadBar]
  let soFar: Bool
  let bandWords: String?
  let note: String?
  let onOpen: () -> Void

  public init(period: LoadPeriod, bars: [LoadBar], soFar: Bool? = nil, bandWords: String? = nil, note: String? = nil, onOpen: @escaping () -> Void = {}) {
    self.period = period
    self.bars = bars
    self.soFar = soFar ?? period.isCurrent
    self.bandWords = bandWords
    self.note = note
    self.onOpen = onOpen
  }

  public var body: some View {
    Button(action: onOpen) {
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text("This week").scaledKicker()
            if soFar { Text("So far").scaledKicker(color: PhoneTheme.inkText) }
            Spacer()
          }
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LoadWords.number(period.loadRounded)).scaledStat().foregroundStyle(PhoneTheme.inkText)
            Text("load").font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
          }
          if let line = bandWords ?? note {
            Text(line).font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text("\(period.sessions) \(period.sessions == 1 ? "session" : "sessions")")
              .font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
          }
          LoadBars(bars: bars, usual: nil, caption: nil, barMax: 48, showValues: false, showLabels: false)
          Text(LoadWords.scopeLabel).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Weekly summary

/// Compact stat tile for a row of three. `StatTile` pads 20 pt, which is too wide for three across a phone.
struct LoadStat: View {
  let kicker: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(kicker).phoneKicker().lineLimit(1).minimumScaleFactor(0.7)
      Text(value).scaledStat().foregroundStyle(PhoneTheme.inkText).lineLimit(1).minimumScaleFactor(0.6)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.card, in: RoundedRectangle(cornerRadius: PhoneTheme.cardRadius))
    .overlay(RoundedRectangle(cornerRadius: PhoneTheme.cardRadius).stroke(PhoneTheme.hairline, lineWidth: 1))
  }
}

/// Last complete week: load, how it compares with the usual week, what changed, one suggestion.
public struct WeeklySummaryScreen: View {
  let compare: LoadCompare
  let weeks: [LoadPeriod]
  let calendar: Calendar
  let usualLine: String
  let onWhy: () -> Void

  public init(compare: LoadCompare, weeks: [LoadPeriod], calendar: Calendar, usualLine: String, onWhy: @escaping () -> Void = {}) {
    self.compare = compare
    self.weeks = weeks
    self.calendar = calendar
    self.usualLine = usualLine
    self.onWhy = onWhy
  }

  private var current: LoadPeriod { compare.current }
  private var heroType: SessionType { current.dominantType ?? .fullSim }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        Text("Week of \(LoadBar.label(current.start, calendar: calendar, format: "d MMM"))").scaledKicker()
        Spacer()
        Wordmark()
      }
      HeroCard(type: heroType) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center) {
            Text("Load").scaledKicker(color: PhoneTheme.sessionText(heroType))
            Spacer()
            if let chip = Self.chip(compare.band) { BandChip(text: chip) }
          }
          Text(LoadWords.number(current.loadRounded)).scaledHero()
          Text(LoadWords.headline(compare)).scaledFont(17, .semibold).fixedSize(horizontal: false, vertical: true)
        }
      }
      PhoneCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("Load by week").scaledKicker()
          LoadBars(bars: LoadBar.bars(weeks, calendar: calendar, flagCurrent: compare.band == .bigJump),
                   usual: compare.usualRounded)
          legend
        }
      }
      HStack(spacing: 8) {
        LoadStat(kicker: "Sessions", value: "\(current.sessions)")
        LoadStat(kicker: "Sim km", value: "\(current.simKm)")
        LoadStat(kicker: "Wall balls", value: LoadWords.number(current.wallBallReps))
      }
      if let changed = LoadWords.whatChanged(compare) {
        Text(changed).scaledFont(17).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
      }
      if let s = LoadWords.suggestion(compare, usualLine: usualLine) {
        Text(s).scaledFont(17, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(LoadWords.scopeLabel)
        if let f = LoadWords.footnote(current) { Text(f) }
      }
      .scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
      .fixedSize(horizontal: false, vertical: true)
      TextLinkButton("Why this number?", action: onWhy)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
  }

  /// Amber cue for the two bands above usual. Lighter and usual stay quiet.
  static func chip(_ band: LoadBand?) -> String? {
    switch band {
    case .bigJump?: return "Big jump"
    case .stepUp?: return "Step up"
    default: return nil
    }
  }

  private var legend: some View {
    HStack(spacing: 12) {
      ForEach(SessionType.allCases) { t in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 3).fill(PhoneTheme.sessionColor(t)).frame(width: 12, height: 12)
          Text(t.title).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
      }
    }
  }
}

/// Bone pill with amber text: readable on the violet hero, never red.
struct BandChip: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
      .foregroundStyle(PhoneTheme.amberText)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(PhoneTheme.paper, in: Capsule())
      .overlay(Capsule().stroke(PhoneTheme.amberText, lineWidth: 1.5))
  }
}

/// Definition, max heart rate and basis. Zone colours appear only here.
public struct WhyLoadSheet: View {
  let period: LoadPeriod
  let maxHR: MaxHeartRate

  public init(period: LoadPeriod, maxHR: MaxHeartRate) {
    self.period = period
    self.maxHR = maxHR
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Why this number?").scaledStatement(size: 28).foregroundStyle(PhoneTheme.inkText)
      Text(LoadWords.definition).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
      Text("How hard is 1 (very easy) to 5 (very hard), from the heart rate zone you were in. Where there is no heart rate it is an estimate from the session plan.")
        .scaledFont(17).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        ForEach(0..<5, id: \.self) { i in
          VStack(spacing: 2) {
            Text("\(i + 1)").font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.ink)
              .frame(maxWidth: .infinity, minHeight: 36)
              .background(Theme.color(Palette.zoneHex[i]), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      Text(maxHR.words + ".").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted).fixedSize(horizontal: false, vertical: true)
      Text(LoadWords.heartRateSessionsLine(period)).scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
      Text(LoadWords.scopeLabel + ". This is an estimate.").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
  }
}

// MARK: - Totals (History)

public enum TotalsMode: String, CaseIterable, Identifiable {
  case week = "Week", month = "Month", year = "Year"
  public var id: String { rawValue }
}

/// Week / Month / Year summary above the History list.
public struct TrainingTotalsCard: View {
  let mode: TotalsMode
  let sessions: [LoadSession]
  let now: Date
  let calendar: Calendar
  let bestFade: Int?
  let onSelect: (TotalsMode) -> Void

  public init(mode: TotalsMode, sessions: [LoadSession], now: Date, calendar: Calendar, bestFade: Int? = nil, onSelect: @escaping (TotalsMode) -> Void = { _ in }) {
    self.mode = mode
    self.sessions = sessions
    self.now = now
    self.calendar = calendar
    self.bestFade = bestFade
    self.onSelect = onSelect
  }

  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 14) {
        picker
        content
      }
    }
  }

  // Drawn, not Picker: ImageRenderer cannot render the UIKit-backed control.
  private var picker: some View {
    HStack(spacing: 4) {
      ForEach(TotalsMode.allCases) { m in
        Button { onSelect(m) } label: {
          Text(m.rawValue).font(.system(size: 15, weight: .heavy))
            .foregroundStyle(m == mode ? Theme.bone : PhoneTheme.inkText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(m == mode ? PhoneTheme.inkText : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(PhoneTheme.paper, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(PhoneTheme.hairline, lineWidth: 1))
  }

  @ViewBuilder private var content: some View {
    switch mode {
    case .week: weekContent
    case .month: monthContent
    case .year: yearContent
    }
  }

  private func tiles(_ a: (String, String), _ b: (String, String), _ c: (String, String)) -> some View {
    HStack(spacing: 8) {
      LoadStat(kicker: a.0, value: a.1)
      LoadStat(kicker: b.0, value: b.1)
      LoadStat(kicker: c.0, value: c.1)
    }
  }

  private var weekContent: some View {
    let weeks = LoadHistory.weeks(sessions, now: now, count: 8, calendar: calendar)
    let cur = weeks[weeks.count - 1]
    let last = LoadCompare.lastComplete(sessions, unit: .week, now: now, calendar: calendar)
    return VStack(alignment: .leading, spacing: 12) {
      Text("This week so far").scaledKicker(color: PhoneTheme.inkText)
      tiles(("Load", LoadWords.number(cur.loadRounded)), ("Sessions", "\(cur.sessions)"), ("Wall balls", LoadWords.number(cur.wallBallReps)))
      if sessions.count <= 1 {
        Text("Your load builds week by week.").font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
      }
      LoadBars(bars: LoadBar.bars(weeks, calendar: calendar, format: "d/M"), usual: last.usualRounded, compactLabels: true)
      if let b = LoadWords.bandWords(last) {
        Text("Last week: \(b.prefix(1).lowercased() + b.dropFirst()).").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.inkText)
      }
      Text(LoadWords.scopeLabel).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
    }
  }

  /// The usual line and the sentence both come from the last complete month, so they cannot disagree. Nil without a comparison.
  static func monthUsual(_ sessions: [LoadSession], now: Date, calendar: Calendar) -> Int? {
    LoadCompare.lastComplete(sessions, unit: .month, now: now, calendar: calendar).usualRounded
  }

  /// "September: 67% more than your usual month."
  static func monthLine(_ last: LoadCompare, calendar: Calendar) -> String? {
    guard let b = LoadWords.bandWords(last) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "MMMM"
    return "\(f.string(from: last.current.start)): \(b.prefix(1).lowercased() + b.dropFirst())."
  }

  private var monthContent: some View {
    let months = LoadHistory.months(sessions, now: now, count: 6, calendar: calendar)
    let cur = months[months.count - 1]
    let last = LoadCompare.lastComplete(sessions, unit: .month, now: now, calendar: calendar)
    return VStack(alignment: .leading, spacing: 12) {
      Text("This month so far").scaledKicker(color: PhoneTheme.inkText)
      tiles(("Load", LoadWords.number(cur.loadRounded)), ("Sessions", "\(cur.sessions)"), ("Best fade", bestFade.map { "\($0) s" } ?? "\u{2013}"))
      LoadBars(bars: LoadBar.bars(months, calendar: calendar, format: "MMM"), usual: last.usualRounded)
      if let line = Self.monthLine(last, calendar: calendar) {
        Text(line).scaledFont(15, .semibold).foregroundStyle(PhoneTheme.inkText)
      }
      Text(LoadWords.scopeLabel).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
    }
  }

  static func hoursText(_ h: Double) -> String {
    let r = (h * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(r)
  }

  private var yearContent: some View {
    let year = calendar.component(.year, from: now)
    let months = LoadHistory.year(sessions, year: year, calendar: calendar)
    let bars = months.enumerated().map { i, p in
      LoadBar(id: i, label: LoadBar.label(p.start, calendar: calendar, format: "MMMMM"), segments: LoadBar.segments(p),
              isCurrent: calendar.isDate(p.start, equalTo: now, toGranularity: .month), soFar: calendar.isDate(p.start, equalTo: now, toGranularity: .month), future: p.start > now)
    }
    let sims = months.reduce(0) { $0 + $1.fullSims }
    let ytd = LoadHistory.sessionsYearToDate(sessions, now: now, calendar: calendar)
    return VStack(alignment: .leading, spacing: 12) {
      tiles(("Sessions", "\(months.reduce(0) { $0 + $1.sessions })"), ("Sim km", LoadWords.number(months.reduce(0) { $0 + $1.simKm })),
            ("Hours", Self.hoursText(months.reduce(0) { $0 + $1.hours })))
      LoadBars(bars: bars, usual: nil, caption: "Taller is more load", showValues: false, compactLabels: true)
      Text("\(sims) full \(sims == 1 ? "sim" : "sims") this year.").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.inkText)
      if let vs = LoadWords.yearVsLast(thisYear: ytd.thisYear, lastYear: ytd.lastYear) {
        Text(vs + ".").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
      }
      Text(LoadWords.scopeLabel).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
    }
  }
}

// MARK: - Notification opt-in

/// Shown after the first complete weekly summary has been viewed. Never at onboarding.
public struct NotifyOptInCard: View {
  let onYes: () -> Void
  let onNo: () -> Void
  public init(onYes: @escaping () -> Void = {}, onNo: @escaping () -> Void = {}) {
    self.onYes = onYes
    self.onNo = onNo
  }

  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 14) {
        Text("Every Monday").scaledKicker()
        Text("Want this every Monday morning? One notification a week, nothing else.")
          .scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
        PrimaryButton("Yes, Mondays", action: onYes)
        TextLinkButton("No thanks", action: onNo)
      }
    }
  }
}
