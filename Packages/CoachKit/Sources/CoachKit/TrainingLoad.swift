import Foundation

// Training load: minutes of work x how hard it was (1 very easy to 5 very hard), per session, then summed by week, month and year.
// Station Coach sessions only. The step weights below are assumed, not measured, and are labelled as estimates wherever they show.

public enum LoadBasis: String, Equatable {
  /// 80% or more of the session had a heart-rate sample.
  case heartRate
  /// 20% up to 80%.
  case mixed
  /// Under 20%: the load is an estimate from the session plan.
  case assumed
}

/// One session's load and the volume it carried.
public struct SessionLoad: Equatable {
  /// Work minutes x weight (zone 1...5 where heart rate covers, the step's assumed weight where it does not).
  public let load: Double
  public let minutes: Double
  /// Minutes at weight 4 or more (zones 4 and 5, or a step assumed that hard).
  public let hardMinutes: Double
  /// Completed runs x 1 km (indoor, no GPS: plan volume).
  public let simKm: Int
  /// Valid wall-ball reps, passed in so the no-rep count plugs in from outside.
  public let wallBallReps: Int
  /// Fixed metres of completed stations (wall balls have none).
  public let stationMetres: Int
  /// Share of the session with a heart-rate sample, 0...1.
  public let coverage: Double
  public var basis: LoadBasis {
    if coverage >= 0.8 { return .heartRate }
    if coverage >= 0.2 { return .mixed }
    return .assumed
  }
  public var usedHeartRate: Bool { basis != .assumed }

  public init(load: Double, minutes: Double, hardMinutes: Double, simKm: Int, wallBallReps: Int, stationMetres: Int, coverage: Double) {
    self.load = load
    self.minutes = minutes
    self.hardMinutes = hardMinutes
    self.simKm = simKm
    self.wallBallReps = wallBallReps
    self.stationMetres = stationMetres
    self.coverage = coverage
  }

  /// Assumed weight for a step with no heart rate behind it. RPE-style, an estimate.
  public static func assumedWeight(_ a: Activity) -> Double {
    switch a {
    case .run, .skierg, .row, .farmersCarry: return 3.5
    case .sledPush, .sledPull, .wallBalls, .burpeeBroadJump, .sandbagLunges: return 4.0
    case .transition: return 3.0
    case .rest: return 2.0
    }
  }
  public static let afterLastSplitWeight = 2.0
  public static let transitionWeight = 3.0

  /// Fixed metres a completed station covers.
  public static func metres(_ a: Activity) -> Int {
    switch a {
    case .skierg, .row: return 1_000
    case .sledPush, .sledPull: return 50
    case .burpeeBroadJump: return 80
    case .farmersCarry: return 200
    case .sandbagLunges: return 100
    default: return 0
    }
  }

  struct Segment { var start: Int64; var end: Int64; var weight: Double }

  /// The session cut into pieces that tile `startedAt..<endedAt`, each with its assumed weight. Runs 2 and later start with
  /// the changeover (`plan.transitionSeconds`) at the transition weight. Time outside any split weighs `afterLastSplitWeight`.
  static func segments(_ r: CoachResult) -> [Segment] {
    let s = r.startedAtEpochMs
    let e = max(r.endedAtEpochMs, s)
    // Splits are epoch ms on the watch; fixtures count from the session start.
    let offset: Int64 = (r.splits.first?.startMs ?? s) < s - 86_400_000 ? s : 0
    var out: [Segment] = []
    var cursor = s
    func add(_ a: Int64, _ b: Int64, _ w: Double) {
      let a2 = max(a, cursor), b2 = min(b, e)
      guard b2 > a2 else { return }
      if a2 > cursor { out.append(Segment(start: cursor, end: a2, weight: afterLastSplitWeight)) }
      out.append(Segment(start: a2, end: b2, weight: w))
      cursor = b2
    }
    for sp in r.splits.sorted(by: { $0.startMs < $1.startMs }) {
      guard let step = r.plan.steps.first(where: { $0.index == sp.stepIndex }) else { continue }
      let a = sp.startMs + offset
      let b = sp.endMs.map { $0 + offset } ?? e
      if step.isRun, (step.runNumber ?? 1) > 1 {
        let t = a + Int64(r.plan.transitionSeconds) * 1000
        add(a, min(t, b), transitionWeight)
        add(t, b, assumedWeight(step.activity))
      } else {
        add(a, b, assumedWeight(step.activity))
      }
    }
    if cursor < e { out.append(Segment(start: cursor, end: e, weight: afterLastSplitWeight)) }
    return out
  }

  /// Load for one session. `wallBallReps` defaults to the session's valid reps; pass another count to override it.
  public static func of(_ result: CoachResult, hr: HeartRateSeries?, maxHR: Int, wallBallReps: Int? = nil) -> SessionLoad {
    let s = result.startedAtEpochMs
    let e = max(result.endedAtEpochMs, s)
    var weighted = 0.0
    var hardMs: Int64 = 0
    var covered: Int64 = 0
    for seg in segments(result) {
      var segCovered: Int64 = 0
      if let hr {
        for iv in hr.intervals(from: seg.start, to: seg.end) {
          let ms = iv.endMs - iv.startMs
          let z = Palette.zone(bpm: iv.bpm, maxHR: maxHR)
          segCovered += ms
          weighted += Double(ms) / 60_000 * Double(z)
          if z >= 4 { hardMs += ms }
        }
      }
      let uncovered = (seg.end - seg.start) - segCovered
      weighted += Double(uncovered) / 60_000 * seg.weight
      if seg.weight >= 4 { hardMs += uncovered }
      covered += segCovered
    }
    var km = 0
    var metres = 0
    for sp in result.splits where sp.endMs != nil {
      guard let step = result.plan.steps.first(where: { $0.index == sp.stepIndex }) else { continue }
      if step.isRun { km += 1 } else { metres += Self.metres(step.activity) }
    }
    let total = e - s
    return SessionLoad(load: weighted, minutes: Double(total) / 60_000, hardMinutes: Double(hardMs) / 60_000, simKm: km,
                       wallBallReps: wallBallReps ?? result.validReps, stationMetres: metres,
                       coverage: total > 0 ? Double(covered) / Double(total) : 0)
  }
}

/// A session's heart rate, for working out the athlete's max.
public struct HeartRateSession: Equatable {
  public let date: Date
  public let series: HeartRateSeries?

  public init(date: Date, series: HeartRateSeries?) {
    self.date = date
    self.series = series
  }
}

/// Max heart rate from the athlete's own sessions: the best 10 s average in the last 180 days, once at least 3 sessions have
/// heart rate. Until then 185, labelled assumed. A max is the best of many, so no single session can lower it.
public struct MaxHeartRate: Equatable {
  public static let assumedBpm = 185
  public static let minSessions = 3
  public static let windowDays = 180

  public let bpm: Int
  public let estimated: Bool
  public let sessionsWithHeartRate: Int

  public static func estimate(_ sessions: [HeartRateSession], now: Date) -> MaxHeartRate {
    let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
    let peaks = sessions.compactMap { s -> Int? in
      guard s.date >= cutoff, s.date <= now else { return nil }
      return s.series?.peakAverage()
    }
    guard peaks.count >= minSessions, let best = peaks.max() else {
      return MaxHeartRate(bpm: assumedBpm, estimated: true, sessionsWithHeartRate: peaks.count)
    }
    return MaxHeartRate(bpm: best, estimated: false, sessionsWithHeartRate: peaks.count)
  }

  /// For the Why sheet.
  public var words: String {
    estimated ? "Max heart rate \(bpm), assumed until you have 3 sessions with heart rate" : "Max heart rate \(bpm), from your sessions"
  }
}

/// A session with its load, as the aggregates see it.
public struct LoadSession: Equatable, Identifiable {
  public let id: String
  public let date: Date
  public let type: SessionType
  public let load: SessionLoad

  public init(id: String, date: Date, type: SessionType, load: SessionLoad) {
    self.id = id
    self.date = date
    self.type = type
    self.load = load
  }
}

/// A record and its heart rate (nil when the file is missing).
public struct LoadInput {
  public let record: SessionRecord
  public let hr: HeartRateSeries?

  public init(record: SessionRecord, hr: HeartRateSeries?) {
    self.record = record
    self.hr = hr
  }
}

public struct TrainingLoadSummary: Equatable {
  public let sessions: [LoadSession]
  public let maxHR: MaxHeartRate
}

public enum TrainingLoad {
  /// Max HR from all the sessions first, then each session's load against it.
  public static func summarise(_ inputs: [LoadInput], now: Date, wallBallReps: (SessionRecord) -> Int? = { _ in nil }) -> TrainingLoadSummary {
    let max = MaxHeartRate.estimate(inputs.map { HeartRateSession(date: $0.record.date, series: $0.hr) }, now: now)
    let sessions = inputs.map { i in
      LoadSession(id: i.record.id, date: i.record.date, type: i.record.type,
                  load: SessionLoad.of(i.record.result, hr: i.hr, maxHR: max.bpm, wallBallReps: wallBallReps(i.record)))
    }
    return TrainingLoadSummary(sessions: sessions, maxHR: max)
  }
}

// MARK: - Periods

public enum LoadUnit: Equatable {
  case week, month

  var component: Calendar.Component { self == .week ? .weekOfYear : .month }
  public var word: String { self == .week ? "week" : "month" }
  /// How many earlier periods "usual" is the mean of.
  var priorCount: Int { self == .week ? 4 : 3 }
}

/// Everything one week, month or year added up to.
public struct LoadPeriod: Equatable {
  public let start: Date
  public let sessions: Int
  public let fullSims: Int
  public let load: Double
  public let minutes: Double
  public let hardMinutes: Double
  public let simKm: Int
  public let wallBallReps: Int
  public let stationMetres: Int
  /// Load by session type, for the stacked bars.
  public let loadByType: [SessionType: Double]
  /// Load from sessions that had no heart rate to speak of.
  public let assumedLoad: Double
  public let sessionsWithHeartRate: Int

  public var loadRounded: Int { Int(load.rounded()) }
  public var hours: Double { minutes / 60 }
  /// More than half the load is an estimate from the plan.
  public var mostlyAssumed: Bool { load > 0 && assumedLoad * 2 > load }
  /// The type carrying the most load (ties go to the larger session); nil when empty.
  public var dominantType: SessionType? {
    loadByType.max { a, b in a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value }?.key
  }

  public static func make(start: Date, sessions list: [LoadSession]) -> LoadPeriod {
    var byType: [SessionType: Double] = [:]
    for s in list { byType[s.type, default: 0] += s.load.load }
    return LoadPeriod(start: start, sessions: list.count, fullSims: list.filter { $0.type == .fullSim }.count,
                      load: list.reduce(0) { $0 + $1.load.load }, minutes: list.reduce(0) { $0 + $1.load.minutes },
                      hardMinutes: list.reduce(0) { $0 + $1.load.hardMinutes }, simKm: list.reduce(0) { $0 + $1.load.simKm },
                      wallBallReps: list.reduce(0) { $0 + $1.load.wallBallReps }, stationMetres: list.reduce(0) { $0 + $1.load.stationMetres },
                      loadByType: byType, assumedLoad: list.filter { $0.load.basis == .assumed }.reduce(0) { $0 + $1.load.load },
                      sessionsWithHeartRate: list.filter { $0.load.usedHeartRate }.count)
  }
}

public enum LoadHistory {
  /// Gregorian, weeks start Monday.
  public static func calendar(timeZone: TimeZone = .current) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = timeZone
    c.firstWeekday = 2
    c.minimumDaysInFirstWeek = 4
    return c
  }

  public static func start(of unit: LoadUnit, containing date: Date, calendar: Calendar) -> Date {
    switch unit {
    case .week:
      return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    case .month:
      return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
  }

  /// `count` periods oldest to newest; the last holds `ending`. Empty periods are kept (a quiet week is a zero bar).
  public static func periods(_ sessions: [LoadSession], unit: LoadUnit, ending: Date, count: Int, calendar: Calendar) -> [LoadPeriod] {
    let last = start(of: unit, containing: ending, calendar: calendar)
    return (0..<max(count, 0)).reversed().map { k in
      let a = calendar.date(byAdding: unit.component, value: -k, to: last) ?? last
      let b = calendar.date(byAdding: unit.component, value: 1, to: a) ?? a
      return LoadPeriod.make(start: a, sessions: sessions.filter { $0.date >= a && $0.date < b })
    }
  }

  public static func weeks(_ sessions: [LoadSession], now: Date, count: Int = 6, calendar: Calendar) -> [LoadPeriod] {
    periods(sessions, unit: .week, ending: now, count: count, calendar: calendar)
  }

  public static func months(_ sessions: [LoadSession], now: Date, count: Int = 6, calendar: Calendar) -> [LoadPeriod] {
    periods(sessions, unit: .month, ending: now, count: count, calendar: calendar)
  }

  /// Twelve months, January to December of `year`; future months are empty.
  public static func year(_ sessions: [LoadSession], year: Int, calendar: Calendar) -> [LoadPeriod] {
    guard let jan = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return [] }
    return (0..<12).map { m in
      let a = calendar.date(byAdding: .month, value: m, to: jan) ?? jan
      let b = calendar.date(byAdding: .month, value: 1, to: a) ?? a
      return LoadPeriod.make(start: a, sessions: sessions.filter { $0.date >= a && $0.date < b })
    }
  }

  /// Sessions from 1 January to `now` this year, and over the same stretch last year.
  public static func sessionsYearToDate(_ sessions: [LoadSession], now: Date, calendar: Calendar) -> (thisYear: Int, lastYear: Int) {
    let y = calendar.component(.year, from: now)
    guard let jan = calendar.date(from: DateComponents(year: y, month: 1, day: 1)),
          let janLast = calendar.date(byAdding: .year, value: -1, to: jan),
          let nowLast = calendar.date(byAdding: .year, value: -1, to: now) else { return (0, 0) }
    return (sessions.filter { $0.date >= jan && $0.date <= now }.count, sessions.filter { $0.date >= janLast && $0.date <= nowLast }.count)
  }
}

// MARK: - Against the usual

public enum LoadBand: String, Equatable, CaseIterable {
  case lighter, usual, stepUp, bigJump

  public static let lighterBelow = 0.80
  public static let usualUpTo = 1.10
  public static let stepUpUpTo = 1.30
  public static let doubleFrom = 1.9

  public static func of(ratio: Double) -> LoadBand {
    if ratio < lighterBelow { return .lighter }
    if ratio <= usualUpTo { return .usual }
    if ratio <= stepUpUpTo { return .stepUp }
    return .bigJump
  }
}

public enum LoadState: Equatable {
  /// Nothing in the period.
  case noSessions
  /// Fewer than 3 sessions across 2 earlier periods: no usual yet.
  case firstWeeks
  /// Two or more empty periods straight before this one.
  case returning
  case compared(LoadBand)
}

/// The mean of the earlier periods, per measure.
public struct UsualPeriod: Equatable {
  public let load: Double
  public let fullSims: Double
  public let wallBallReps: Double
  public let hardMinutes: Double
  public let minutes: Double
}

public struct LoadCompare: Equatable {
  public let unit: LoadUnit
  public let current: LoadPeriod
  public let state: LoadState
  /// current load / usual load; nil unless compared.
  public let ratio: Double?
  public let usual: UsualPeriod?

  public var usualRounded: Int? { usual.map { Int($0.load.rounded()) } }
  public var band: LoadBand? { if case .compared(let b) = state { return b }; return nil }
  /// Distance from usual in whole percent.
  public var percent: Int? { ratio.map { Int((abs($0 - 1) * 100).rounded()) } }
  public var isDouble: Bool { (ratio ?? 0) >= LoadBand.doubleFrom }

  /// `periodStart` is any date in the period to judge. Weeks before the first session do not count toward usual; empty weeks do.
  public static func compare(_ sessions: [LoadSession], periodStart: Date, unit: LoadUnit = .week, calendar: Calendar) -> LoadCompare {
    let cur = LoadHistory.periods(sessions, unit: unit, ending: periodStart, count: 1, calendar: calendar)[0]
    func result(_ state: LoadState, ratio: Double? = nil, usual: UsualPeriod? = nil) -> LoadCompare {
      LoadCompare(unit: unit, current: cur, state: state, ratio: ratio, usual: usual)
    }
    guard cur.sessions > 0 else { return result(.noSessions) }
    guard let first = sessions.filter({ $0.date < cur.start }).map(\.date).min() else { return result(.firstWeeks) }
    let priors = (1...unit.priorCount).map { k -> LoadPeriod in
      let a = calendar.date(byAdding: unit.component, value: -k, to: cur.start) ?? cur.start
      return LoadHistory.periods(sessions, unit: unit, ending: a, count: 1, calendar: calendar)[0]
    }
    if priors[0].sessions == 0, priors[1].sessions == 0 { return result(.returning) }
    let firstStart = LoadHistory.start(of: unit, containing: first, calendar: calendar)
    let counted = priors.filter { $0.start >= firstStart }
    let total = counted.reduce(0) { $0 + $1.sessions }
    guard total >= 3, counted.filter({ $0.sessions > 0 }).count >= 2 else { return result(.firstWeeks) }
    func mean(_ f: (LoadPeriod) -> Double) -> Double { counted.reduce(0) { $0 + f($1) } / Double(counted.count) }
    let usual = UsualPeriod(load: mean { $0.load }, fullSims: mean { Double($0.fullSims) }, wallBallReps: mean { Double($0.wallBallReps) },
                            hardMinutes: mean { $0.hardMinutes }, minutes: mean { $0.minutes })
    let ratio = cur.load / usual.load
    return result(.compared(LoadBand.of(ratio: ratio)), ratio: ratio, usual: usual)
  }
}

// MARK: - Words

public enum LoadWords {
  public static let scopeLabel = "Station Coach sessions only"
  public static let definition = "Work minutes x how hard. A 60-minute full sim is usually 220 to 280."
  public static let assumedFootnote = "Most of this week had no heart rate, so load is an estimate from the session plan."

  /// 1,234.
  public static func number(_ n: Int) -> String {
    let digits = String(abs(n))
    var out = ""
    for (i, ch) in digits.reversed().enumerated() {
      if i > 0, i % 3 == 0 { out.append(",") }
      out.append(ch)
    }
    return (n < 0 ? "-" : "") + String(out.reversed())
  }

  /// "2", "1.5".
  static func mean(_ d: Double) -> String {
    let r = (d * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(r)
  }

  /// "about your usual week", "12% more than your usual week", "about double your usual week".
  static func phrase(_ c: LoadCompare) -> String? {
    guard let band = c.band, let p = c.percent else { return nil }
    let u = c.unit.word
    switch band {
    case .usual: return "about your usual \(u)"
    case .lighter: return "\(p)% less than your usual \(u)"
    case .stepUp: return "\(p)% more than your usual \(u)"
    case .bigJump: return c.isDouble ? "about double your usual \(u)" : "\(p)% more than your usual \(u)"
    }
  }

  /// The band in words for the card: "About your usual week". Nil unless compared.
  public static func bandWords(_ c: LoadCompare) -> String? {
    phrase(c).map { $0.prefix(1).uppercased() + $0.dropFirst() }
  }

  /// "486 load, 12% more than your usual week (412)." `includeUsual: false` drops the bracket, for the notification.
  public static func headline(_ c: LoadCompare, includeUsual: Bool = true) -> String {
    let load = number(c.current.loadRounded)
    switch c.state {
    case .noSessions: return "No sessions this \(c.unit.word)."
    case .firstWeeks: return "\(load) load. Your usual \(c.unit.word) takes shape after 3 sessions."
    case .returning: return "\(load) load, your first \(c.unit.word) back. We compare from next \(c.unit.word)."
    case .compared:
      let usual = includeUsual ? c.usualRounded.map { " (\(number($0)))" } ?? "" : ""
      return "\(load) load, \(phrase(c) ?? "")\(usual)."
    }
  }

  /// What moved most, first rule wins. Nil unless compared.
  public static func whatChanged(_ c: LoadCompare) -> String? {
    guard case .compared = c.state, let u = c.usual else { return nil }
    let cur = c.current
    let sims = Double(cur.fullSims)
    if abs(sims - u.fullSims) >= 1 {
      return "\(cur.fullSims) full \(cur.fullSims == 1 ? "sim" : "sims"), usual \(mean(u.fullSims))."
    }
    let reps = Double(cur.wallBallReps)
    if abs(reps - u.wallBallReps) >= 50, u.wallBallReps == 0 || abs(reps - u.wallBallReps) / u.wallBallReps >= 0.5 {
      return "\(number(cur.wallBallReps)) wall balls, usual \(number(Int(u.wallBallReps.rounded())))."
    }
    if abs(cur.hardMinutes - u.hardMinutes) >= 10, u.hardMinutes == 0 || abs(cur.hardMinutes - u.hardMinutes) / u.hardMinutes >= 0.5 {
      return "\(Int(cur.hardMinutes.rounded())) hard minutes, usual \(Int(u.hardMinutes.rounded()))."
    }
    return "\(Int(cur.minutes.rounded())) work minutes, usual \(Int(u.minutes.rounded()))."
  }

  /// One suggestion. `usualLine` is the coach's own line (`Recommendation.pick(...).line`) for a usual week.
  public static func suggestion(_ c: LoadCompare, usualLine: String) -> String? {
    switch c.state {
    case .noSessions, .returning: return nil
    case .firstWeeks: return "Three sessions in and this compares you with your own usual."
    case .compared(let band):
      let usual = c.usual?.load ?? 0
      switch band {
      case .bigJump:
        let cap = Int((usual * 1.1 / 10).rounded()) * 10
        return "Big week. Keep next week near \(number(cap)) and make one session a half sim."
      case .stepUp: return "Good step. Hold here a week before adding a session."
      case .usual: return usualLine
      case .lighter: return "Lighter week. Back to about \(number(Int(usual.rounded()))) next week is fine."
      }
    }
  }

  /// Footnote when most of the load is an estimate; nil otherwise.
  public static func footnote(_ p: LoadPeriod) -> String? { p.mostlyAssumed ? assumedFootnote : nil }

  /// "2 of 3 sessions used your heart rate."
  public static func heartRateSessionsLine(_ p: LoadPeriod) -> String {
    "\(p.sessionsWithHeartRate) of \(p.sessions) \(p.sessions == 1 ? "session" : "sessions") used your heart rate."
  }

  /// "19 more sessions than this time last year"; nil when there was nothing last year.
  public static func yearVsLast(thisYear: Int, lastYear: Int) -> String? {
    guard lastYear > 0 else { return nil }
    let d = thisYear - lastYear
    if d == 0 { return "The same number of sessions as this time last year" }
    return "\(abs(d)) \(d > 0 ? "more" : "fewer") \(abs(d) == 1 ? "session" : "sessions") than this time last year"
  }
}

/// The Monday notification. Pure strings; scheduling is the app's job.
public enum WeeklyNotice {
  public struct Content: Equatable {
    public let title: String
    public let body: String
  }

  /// nil = send nothing: an empty week never nags, and a first week with fewer than 2 sessions is not worth a ping.
  /// `watchHasUnsent` adds the sync caveat.
  public static func content(for c: LoadCompare, watchHasUnsent: Bool = false) -> Content? {
    guard c.current.sessions > 0 else { return nil }
    if c.state == .firstWeeks, c.current.sessions < 2 { return nil }
    var body = LoadWords.headline(c, includeUsual: false) + " Tap for what changed."
    if watchHasUnsent { body += " (sync your watch for the full week)" }
    return Content(title: "Your week: \(LoadWords.number(c.current.loadRounded)) load", body: body)
  }
}

// MARK: - Sample fixtures

/// Synthetic scenarios for CI screens and tests. No real data.
public enum LoadSample: String, CaseIterable {
  case usual, stepUp, bigJump, lighter, firstWeeks, returning
  /// The usual scenario with every session lacking heart rate.
  case noHeartRate
  /// The usual scenario with partial heart rate.
  case mixedHeartRate
}

public struct LoadSampleData {
  public let sessions: [LoadSession]
  /// The Monday of the week to judge (the newest of the six).
  public let weekStart: Date
  public let calendar: Calendar
  public var compare: LoadCompare { LoadCompare.compare(sessions, periodStart: weekStart, unit: .week, calendar: calendar) }
  public var weeks: [LoadPeriod] { LoadHistory.weeks(sessions, now: weekStart, count: 6, calendar: calendar) }
}

public extension TrainingLoad {
  /// Monday 19 Oct 2026, 00:00 UTC.
  static let sampleWeekStartEpoch: TimeInterval = 1_792_368_000

  static var sampleCalendar: Calendar { LoadHistory.calendar(timeZone: TimeZone(identifier: "UTC")!) }

  enum SampleKind { case full, half, focus }
  enum SampleHeartRate { case full, mixed, none }

  private static func sampleLoad(_ kind: SampleKind, _ hr: SampleHeartRate) -> SessionLoad {
    let coverage: Double = hr == .full ? 1 : hr == .mixed ? 0.5 : 0
    switch kind {
    case .full: return SessionLoad(load: 240, minutes: 60, hardMinutes: 28, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: coverage)
    case .half: return SessionLoad(load: 120, minutes: 30, hardMinutes: 12, simKm: 4, wallBallReps: 0, stationMetres: 1_180, coverage: coverage)
    case .focus: return SessionLoad(load: 100, minutes: 28, hardMinutes: 10, simKm: 3, wallBallReps: 150, stationMetres: 0, coverage: coverage)
    }
  }

  /// Six weeks, oldest first, each a list of session kinds; the last week is the one to judge.
  static func sample(_ s: LoadSample) -> LoadSampleData {
    let cal = sampleCalendar
    let f = SampleKind.full, h = SampleKind.half
    var hr = SampleHeartRate.full
    let weeks: [[SampleKind]]
    switch s {
    case .usual, .noHeartRate, .mixedHeartRate: weeks = [[f], [f, f], [f, f], [f, f], [f, f], [f, f]]
    case .stepUp: weeks = [[f], [f, f], [f, f], [f, f], [f, f], [f, f, h]]
    case .bigJump: weeks = [[f], [f, f], [f, f], [f, f], [f, f], [f, f, f, f]]
    case .lighter: weeks = [[f], [f, f], [f, f], [f, f], [f, f], [f]]
    case .firstWeeks: weeks = [[], [], [], [], [f], [f, h]]
    case .returning: weeks = [[f, f], [f], [], [], [], [f]]
    }
    if s == .noHeartRate { hr = .none }
    if s == .mixedHeartRate { hr = .mixed }
    let monday = Date(timeIntervalSince1970: sampleWeekStartEpoch)
    let days = [1, 3, 5, 6]
    var out: [LoadSession] = []
    for (w, kinds) in weeks.enumerated() {
      for (i, kind) in kinds.enumerated() {
        let day = (w - 5) * 7 + days[i]
        let date = cal.date(byAdding: .day, value: day, to: monday)!.addingTimeInterval(10 * 3_600)
        let type: SessionType = kind == .full ? .fullSim : kind == .half ? .halfSim : .wallBallFocus
        out.append(LoadSession(id: "sample-\(w)-\(i)", date: date, type: type, load: sampleLoad(kind, hr)))
      }
    }
    return LoadSampleData(sessions: out, weekStart: monday, calendar: cal)
  }

  /// A finished session on plan, step after step, for a real load calculation in screens and tests.
  static func sampleResult(_ type: SessionType, startEpochMs: Int64 = 1_792_368_000_000 + 36_000_000, target: Int = 3_600) -> CoachResult {
    let plan = PlanBuilder.build(division: .openMen, target: target, type: type)
    var t = startEpochMs
    var splits: [StepSplit] = []
    for step in plan.steps {
      let d = Int64(step.targetSeconds) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    return CoachResult(plan: plan, splits: splits, early: false, repTimesMs: [], repCorrection: 0, startedAtEpochMs: startEpochMs, endedAtEpochMs: t)
  }

  /// One sample a second, hard in every step: run 165, transition 160, stations 170-175. nil for `.none`;
  /// `.mixed` stops after 55% of the session.
  static func sampleHeartRate(for r: CoachResult, _ mode: SampleHeartRate) -> HeartRateSeries? {
    guard mode != .none else { return nil }
    let end = mode == .full ? r.endedAtEpochMs : r.startedAtEpochMs + Int64(Double(r.endedAtEpochMs - r.startedAtEpochMs) * 0.55)
    var out: [HeartRateSample] = []
    var t = r.startedAtEpochMs
    while t < end {
      let step = r.splits.first { $0.startMs <= t && t < ($0.endMs ?? r.endedAtEpochMs) }.flatMap { sp in r.plan.steps.first { $0.index == sp.stepIndex } }
      let bpm: Int
      switch step?.activity {
      case .run?: bpm = 165
      case .sledPush?, .sledPull?, .wallBalls?: bpm = 175
      case nil: bpm = 120
      default: bpm = 170
      }
      out.append(HeartRateSample(epochMs: t, bpm: bpm))
      t += 1000
    }
    return HeartRateSeries(samples: out)
  }
}
