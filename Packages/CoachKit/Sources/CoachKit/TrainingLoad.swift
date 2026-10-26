import Foundation

// Training load: minutes of work x how hard it was (1 very easy to 5 very hard), per session, then summed by week, month and year.
// Station Coach sessions only. Where heart rate is missing the step weights are assumed (calibrated to the athlete's own heart rate
// where there is enough of it) and are labelled as estimates wherever they show. Zones are Edwards-style.

public enum LoadBasis: String, Equatable {
  /// 80% or more of the session had a heart-rate sample.
  case heartRate
  /// 20% up to 80%.
  case mixed
  /// Under 20%: the load is an estimate from the session plan.
  case assumed
}

extension CoachResult {
  /// Splits as the watch writes them: epoch ms, the first starting within 5 s of the session start and every one inside the session.
  /// No splits at all is valid (nothing to read). Anything else is corrupt data, not a different clock.
  public var splitsLookValid: Bool {
    let slack: Int64 = 5_000
    guard let first = splits.map(\.startMs).min() else { return true }
    guard abs(first - startedAtEpochMs) <= slack else { return false }
    return splits.allSatisfy { sp in
      sp.startMs >= startedAtEpochMs - slack && (sp.endMs ?? sp.startMs) <= endedAtEpochMs + slack && (sp.endMs ?? sp.startMs) >= sp.startMs
    }
  }
}

/// One session's load and the volume it carried.
public struct SessionLoad: Equatable {
  /// Work minutes x weight (zone 1...5 where heart rate covers, the step's assumed weight where it does not).
  public let load: Double
  public let minutes: Double
  /// Minutes in zones 4 and 5, from heart-rate-covered time only. Never inferred from the assumed weights; `coverage` says how
  /// much of the session this speaks for.
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

  /// Default assumed weight for a step with no heart rate behind it. Set to what a hard sim measures (runs zone 4, stations
  /// zone 4 to 5) so a session with and without heart rate lands on one scale; `AssumedWeights.calibrated` replaces it per athlete.
  public static func assumedWeight(_ a: Activity) -> Double { AssumedWeights.defaults.weight(a) }
  public static let afterLastSplitWeight = 2.0
  /// Whole-session weight when the splits cannot be trusted.
  public static let genericWeight = 3.5
  public static let transitionWeight = 3.5

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

  struct Segment { var start: Int64; var end: Int64; var weight: Double; var activity: Activity? = nil }

  /// The session cut into pieces that tile `startedAt..<endedAt`, each with its assumed weight. Runs 2 and later start with
  /// the changeover (`plan.transitionSeconds`) at the transition weight. Time outside any split weighs `afterLastSplitWeight`.
  static func segments(_ r: CoachResult, weights: AssumedWeights = .defaults) -> [Segment] {
    let s = r.startedAtEpochMs
    let e = max(r.endedAtEpochMs, s)
    // Splits are epoch ms, as the watch writes them. Corrupt ones are not re-based: the whole session takes a generic weight.
    guard r.splitsLookValid else { return e > s ? [Segment(start: s, end: e, weight: genericWeight)] : [] }
    var out: [Segment] = []
    var cursor = s
    func add(_ a: Int64, _ b: Int64, _ act: Activity) {
      let a2 = max(a, cursor), b2 = min(b, e)
      guard b2 > a2 else { return }
      if a2 > cursor { out.append(Segment(start: cursor, end: a2, weight: afterLastSplitWeight)) }
      out.append(Segment(start: a2, end: b2, weight: weights.weight(act), activity: act))
      cursor = b2
    }
    for sp in r.splits.sorted(by: { $0.startMs < $1.startMs }) {
      guard let step = r.plan.steps.first(where: { $0.index == sp.stepIndex }) else { continue }
      let a = sp.startMs
      let b = sp.endMs ?? e
      if step.isRun, (step.runNumber ?? 1) > 1 {
        let t = a + Int64(r.plan.transitionSeconds) * 1000
        add(a, min(t, b), .transition)
        add(t, b, step.activity)
      } else {
        add(a, b, step.activity)
      }
    }
    if cursor < e { out.append(Segment(start: cursor, end: e, weight: afterLastSplitWeight)) }
    return out
  }

  /// Load for one session. `wallBallReps` defaults to the session's valid reps; pass another count to override it.
  public static func of(_ result: CoachResult, hr: HeartRateSeries?, maxHR: Int, wallBallReps: Int? = nil, weights: AssumedWeights = .defaults) -> SessionLoad {
    let s = result.startedAtEpochMs
    let e = max(result.endedAtEpochMs, s)
    var weighted = 0.0
    var hardMs: Int64 = 0
    var covered: Int64 = 0
    for seg in segments(result, weights: weights) {
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
      covered += segCovered
    }
    var km = 0
    var metres = 0
    // The watch closes the step in progress when a session ends early, so that step was quit, not completed.
    let quit = result.early ? result.splits.max(by: { $0.startMs < $1.startMs })?.stepIndex : nil
    for sp in result.splits where sp.endMs != nil && sp.stepIndex != quit && result.splitsLookValid {
      guard let step = result.plan.steps.first(where: { $0.index == sp.stepIndex }) else { continue }
      if step.isRun { km += 1 } else { metres += Self.metres(step.activity) }
    }
    let total = e - s
    return SessionLoad(load: weighted, minutes: Double(total) / 60_000, hardMinutes: Double(hardMs) / 60_000, simKm: km,
                       wallBallReps: wallBallReps ?? result.validReps, stationMetres: metres,
                       coverage: total > 0 ? Double(covered) / Double(total) : 0)
  }
}

/// What a minute of each activity weighs when heart rate is missing.
public struct AssumedWeights: Equatable {
  public var byActivity: [Activity: Double]

  public init(byActivity: [Activity: Double]) { self.byActivity = byActivity }

  public static let defaults = AssumedWeights(byActivity: [
    .run: 4.0, .transition: 3.5,
    .skierg: 4.5, .row: 4.5, .farmersCarry: 4.5, .sledPush: 4.5, .sledPull: 4.5, .burpeeBroadJump: 4.5, .sandbagLunges: 4.5, .wallBalls: 4.5,
    .rest: 2.0,
  ])
  /// Seconds of heart rate an activity needs before its own mean replaces the default.
  public static let minCalibrationSeconds = 120.0

  public func weight(_ a: Activity) -> Double { byActivity[a] ?? Self.defaults.byActivity[a] ?? 3.5 }

  /// Per activity, the athlete's own time-weighted mean zone over their heart-rate-covered time in the last 180 days; the default
  /// where an activity has under `minCalibrationSeconds`. A session with no heart rate then scores on the same scale as one with.
  public static func calibrated(_ inputs: [LoadInput], maxHR: Int, now: Date) -> AssumedWeights {
    let cutoff = now.addingTimeInterval(-Double(MaxHeartRate.windowDays) * 86_400)
    var zoneSeconds: [Activity: Double] = [:]
    var seconds: [Activity: Double] = [:]
    for i in inputs where i.record.date >= cutoff && i.record.date <= now && i.record.result.splitsLookValid {
      guard let hr = i.hr else { continue }
      for seg in SessionLoad.segments(i.record.result) {
        guard let act = seg.activity else { continue }
        for iv in hr.intervals(from: seg.start, to: seg.end) {
          let sec = Double(iv.endMs - iv.startMs) / 1000
          zoneSeconds[act, default: 0] += sec * Double(Palette.zone(bpm: iv.bpm, maxHR: maxHR))
          seconds[act, default: 0] += sec
        }
      }
    }
    var out = defaults
    for (act, sec) in seconds where sec >= minCalibrationSeconds {
      out.byActivity[act] = zoneSeconds[act, default: 0] / sec
    }
    return out
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

/// Max heart rate from the athlete's own sessions: the best 30 s average of each session in the last 180 days, once at least
/// 3 sessions have heart rate. Until then 185, labelled assumed. One wrist artefact must not set it for 180 days, so the top
/// peak counts only when the next session is within 5 bpm of it; otherwise the second-highest peak is used.
public struct MaxHeartRate: Equatable {
  public static let assumedBpm = 185
  public static let minSessions = 3
  public static let windowDays = 180
  public static let confirmBpm = 5

  public let bpm: Int
  public let estimated: Bool
  public let sessionsWithHeartRate: Int

  public static func estimate(_ sessions: [HeartRateSession], now: Date) -> MaxHeartRate {
    let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
    let peaks = sessions.compactMap { s -> Int? in
      guard s.date >= cutoff, s.date <= now else { return nil }
      return s.series?.peakAverage()
    }
    let ranked = peaks.sorted(by: >)
    guard ranked.count >= minSessions else {
      return MaxHeartRate(bpm: assumedBpm, estimated: true, sessionsWithHeartRate: ranked.count)
    }
    let best = ranked[0] - ranked[1] <= confirmBpm ? ranked[0] : ranked[1]
    return MaxHeartRate(bpm: best, estimated: false, sessionsWithHeartRate: ranked.count)
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
  /// False for a session ended early: it carries load and volume but is not counted as a full sim.
  public let isComplete: Bool

  public init(id: String, date: Date, type: SessionType, load: SessionLoad, isComplete: Bool = true) {
    self.id = id
    self.date = date
    self.type = type
    self.load = load
    self.isComplete = isComplete
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
  public let weights: AssumedWeights
  public let maxHR: MaxHeartRate
  /// Ids of sessions left out because their splits looked corrupt.
  public let skippedSessionIds: [String]
}

public enum TrainingLoad {
  /// Max HR from all the sessions first, then each session's load against it.
  public static func summarise(_ inputs: [LoadInput], now: Date, wallBallReps: (SessionRecord) -> Int? = { _ in nil }) -> TrainingLoadSummary {
    let max = MaxHeartRate.estimate(inputs.map { HeartRateSession(date: $0.record.date, series: $0.hr) }, now: now)
    let weights = AssumedWeights.calibrated(inputs, maxHR: max.bpm, now: now)
    let valid = inputs.filter { $0.record.result.splitsLookValid }
    let skipped = inputs.filter { !$0.record.result.splitsLookValid }.map(\.record.id)
    for id in skipped { NSLog("TrainingLoad: skipped session %@, its splits look corrupt", id) }
    let sessions = valid.map { i in
      LoadSession(id: i.record.id, date: i.record.date, type: i.record.type,
                  load: SessionLoad.of(i.record.result, hr: i.hr, maxHR: max.bpm, wallBallReps: wallBallReps(i.record), weights: weights),
                  isComplete: i.record.isComplete)
    }
    return TrainingLoadSummary(sessions: sessions, weights: weights, maxHR: max, skippedSessionIds: skipped)
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
  /// Minutes that had a heart-rate sample behind them.
  public let heartRateMinutes: Double
  /// The period `now` falls in: still running, so its numbers are so far.
  public let isCurrent: Bool

  public var loadRounded: Int { LoadWords.int(load) }
  /// Share of the period's minutes with a heart-rate sample, 0...1.
  public var heartRateShare: Double { minutes > 0 ? heartRateMinutes / minutes : 0 }
  public var hours: Double { minutes / 60 }
  /// More than half the load is an estimate from the plan.
  public var mostlyAssumed: Bool { load > 0 && assumedLoad * 2 > load }
  /// The type carrying the most load (ties go to the larger session); nil when empty.
  public var dominantType: SessionType? {
    func rank(_ t: SessionType) -> Int { SessionType.allCases.firstIndex(of: t) ?? 0 }
    return loadByType.max { a, b in
      a.value == b.value ? rank(a.key) > rank(b.key) : a.value < b.value
    }?.key
  }

  public static func make(start: Date, sessions list: [LoadSession], isCurrent: Bool = false) -> LoadPeriod {
    var byType: [SessionType: Double] = [:]
    for s in list { byType[s.type, default: 0] += s.load.load }
    return LoadPeriod(start: start, sessions: list.count, fullSims: list.filter { $0.type == .fullSim && $0.isComplete }.count,
                      load: list.reduce(0) { $0 + $1.load.load }, minutes: list.reduce(0) { $0 + $1.load.minutes },
                      hardMinutes: list.reduce(0) { $0 + $1.load.hardMinutes }, simKm: list.reduce(0) { $0 + $1.load.simKm },
                      wallBallReps: list.reduce(0) { $0 + $1.load.wallBallReps }, stationMetres: list.reduce(0) { $0 + $1.load.stationMetres },
                      loadByType: byType, assumedLoad: list.filter { $0.load.basis == .assumed }.reduce(0) { $0 + $1.load.load },
                      sessionsWithHeartRate: list.filter { $0.load.usedHeartRate }.count,
                      heartRateMinutes: list.reduce(0) { $0 + $1.load.minutes * $1.load.coverage }, isCurrent: isCurrent)
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
  public static func periods(_ sessions: [LoadSession], unit: LoadUnit, ending: Date, count: Int, calendar: Calendar, currentAt: Date? = nil) -> [LoadPeriod] {
    let last = start(of: unit, containing: ending, calendar: calendar)
    return (0..<max(count, 0)).reversed().map { k in
      let a = calendar.date(byAdding: unit.component, value: -k, to: last) ?? last
      let b = calendar.date(byAdding: unit.component, value: 1, to: a) ?? a
      return LoadPeriod.make(start: a, sessions: sessions.filter { $0.date >= a && $0.date < b }, isCurrent: currentAt.map { $0 >= a && $0 < b } ?? false)
    }
  }

  public static func weeks(_ sessions: [LoadSession], now: Date, count: Int = 6, calendar: Calendar) -> [LoadPeriod] {
    periods(sessions, unit: .week, ending: now, count: count, calendar: calendar, currentAt: now)
  }

  public static func months(_ sessions: [LoadSession], now: Date, count: Int = 6, calendar: Calendar) -> [LoadPeriod] {
    periods(sessions, unit: .month, ending: now, count: count, calendar: calendar, currentAt: now)
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
  /// Mean share of minutes with heart rate across the counted periods.
  public let heartRateShare: Double
}

public struct LoadCompare: Equatable {
  public let unit: LoadUnit
  public let current: LoadPeriod
  public let state: LoadState
  /// current load / usual load; nil unless compared.
  public let ratio: Double?
  public let usual: UsualPeriod?

  public var usualRounded: Int? { usual.map { LoadWords.int($0.load) } }
  public var band: LoadBand? { if case .compared(let b) = state { return b }; return nil }
  /// Distance from usual in whole percent.
  public var percent: Int? { ratio.map { LoadWords.int(abs($0 - 1) * 100) } }
  public var isDouble: Bool { (ratio ?? 0) >= LoadBand.doubleFrom }

  /// The last period that has finished at `now` (last Monday to Sunday, or last month): what the weekly summary and the
  /// notification judge. The period `now` is in is only ever "so far".
  public static func lastComplete(_ sessions: [LoadSession], unit: LoadUnit = .week, now: Date, calendar: Calendar) -> LoadCompare {
    let thisStart = LoadHistory.start(of: unit, containing: now, calendar: calendar)
    let prev = calendar.date(byAdding: unit.component, value: -1, to: thisStart) ?? thisStart
    return compare(sessions, periodStart: prev, unit: unit, calendar: calendar, now: now)
  }

  /// The period `now` is in, so far. Its state says whether a comparison is coming (first weeks, returning, compared), but
  /// the screens never show a band for it: a week in progress is only ever "so far".
  public static func current(_ sessions: [LoadSession], unit: LoadUnit = .week, now: Date, calendar: Calendar) -> LoadCompare {
    compare(sessions, periodStart: now, unit: unit, calendar: calendar, now: now)
  }

  /// `periodStart` is any date in the period to judge. Periods before the first session do not count toward usual; empty ones
  /// do. A first month that began after its middle is left out of usual (a few days would drag it down). After a break of two
  /// or more empty periods the comparison waits for two non-empty periods, then uses only those. `now` marks the period in progress.
  public static func compare(_ sessions: [LoadSession], periodStart: Date, unit: LoadUnit = .week, calendar: Calendar, now: Date? = nil) -> LoadCompare {
    let cur = LoadHistory.periods(sessions, unit: unit, ending: periodStart, count: 1, calendar: calendar, currentAt: now)[0]
    func result(_ state: LoadState, ratio: Double? = nil, usual: UsualPeriod? = nil) -> LoadCompare {
      LoadCompare(unit: unit, current: cur, state: state, ratio: ratio, usual: usual)
    }
    guard cur.sessions > 0 else { return result(.noSessions) }
    guard let first = sessions.filter({ $0.date < cur.start }).map(\.date).min() else { return result(.firstWeeks) }
    // Nearest first.
    let priors = (1...unit.priorCount).map { k -> LoadPeriod in
      let a = calendar.date(byAdding: unit.component, value: -k, to: cur.start) ?? cur.start
      return LoadHistory.periods(sessions, unit: unit, ending: a, count: 1, calendar: calendar)[0]
    }
    var firstStart = LoadHistory.start(of: unit, containing: first, calendar: calendar)
    if unit == .month, let end = calendar.date(byAdding: .month, value: 1, to: firstStart),
       first.timeIntervalSince(firstStart) > end.timeIntervalSince(firstStart) / 2 {
      firstStart = end
    }
    // A break: the nearest pair of empty periods that sits after the first session.
    var window = priors
    var afterBreak = false
    if let j = (0..<(priors.count - 1)).first(where: { priors[$0].sessions == 0 && priors[$0 + 1].sessions == 0 && priors[$0 + 1].start >= firstStart }) {
      if priors[0..<j].filter({ $0.sessions > 0 }).count < 2 { return result(.returning) }
      window = Array(priors[0..<j])
      afterBreak = true
    }
    // Someone with history from before the window is not new: a thin stretch reads as a break, not as a first period.
    let thin: LoadState = afterBreak || first < priors[priors.count - 1].start ? .returning : .firstWeeks
    let counted = window.filter { $0.start >= firstStart }
    let total = counted.reduce(0) { $0 + $1.sessions }
    guard total >= 3, counted.filter({ $0.sessions > 0 }).count >= 2 else { return result(thin) }
    func mean(_ f: (LoadPeriod) -> Double) -> Double { counted.reduce(0) { $0 + f($1) } / Double(counted.count) }
    let usual = UsualPeriod(load: mean { $0.load }, fullSims: mean { Double($0.fullSims) }, wallBallReps: mean { Double($0.wallBallReps) },
                            hardMinutes: mean { $0.hardMinutes }, minutes: mean { $0.minutes }, heartRateShare: mean { $0.heartRateShare })
    let ratio = cur.load / usual.load
    // No usual to compare with (all load zero or not a number): say so rather than invent a band.
    guard usual.load.isFinite, usual.load > 0, ratio.isFinite else { return result(thin) }
    return result(.compared(LoadBand.of(ratio: ratio)), ratio: ratio, usual: usual)
  }
}

// MARK: - Words

public enum LoadWords {
  public static let scopeLabel = "Station Coach sessions only"
  public static let definition = "Work minutes x how hard. A 60-minute full sim is usually 220 to 280."
  public static let assumedFootnote = "Most of this week had no heart rate, so load is an estimate from the session plan."

  /// A whole number from a Double that may be NaN or infinite: those read as 0, huge values clamp.
  public static func int(_ d: Double) -> Int {
    guard d.isFinite else { return 0 }
    return Int(min(max(d.rounded(), -1e9), 1e9))
  }

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
    case .firstWeeks: return "\(load) load. Your usual \(c.unit.word) takes shape after 3 sessions across 2 \(c.unit.word)s."
    case .returning: return "\(load) load. Back after a break. Your usual comes back after 3 sessions across 2 \(c.unit.word)s."
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
      return "\(number(cur.wallBallReps)) wall balls, usual \(number(int(u.wallBallReps)))."
    }
    // Hard minutes are measured from heart rate only, so they are compared only when both sides mostly had it.
    if cur.heartRateShare >= 0.5, u.heartRateShare >= 0.5, abs(cur.hardMinutes - u.hardMinutes) >= 10, u.hardMinutes == 0 || abs(cur.hardMinutes - u.hardMinutes) / u.hardMinutes >= 0.5 {
      return "\(int(cur.hardMinutes)) hard minutes, usual \(int(u.hardMinutes))."
    }
    return "\(int(cur.minutes)) work minutes, usual \(int(u.minutes))."
  }

  /// One suggestion, always a description. Never an instruction, and never a coach line from `Recommendation.pick`.
  public static func suggestion(_ c: LoadCompare) -> String? {
    switch c.state {
    case .noSessions, .returning, .firstWeeks: return nil
    case .compared(let band):
      let usual = c.usual?.load ?? 0
      switch band {
      case .bigJump:
        let cap = int(usual * 1.1 / 10) * 10
        return "Next week near \(number(cap)), just above your usual, would balance it."
      case .stepUp: return "A good step up. Holding here a week would let it settle."
      case .usual: return "A steady week, in line with your usual. That keeps the fade comparisons fair."
      case .lighter: return "A lighter week. About \(number(int(usual))) next week would be back to your usual."
      }
    }
  }

  /// The one-line note on the Home card while there is no comparison; nil once there is.
  public static func cardNote(_ c: LoadCompare) -> String? {
    switch c.state {
    case .firstWeeks: return "Your usual \(c.unit.word) takes shape after 3 sessions across 2 \(c.unit.word)s."
    case .returning: return "Back after a break. Your usual comes back after 3 sessions across 2 \(c.unit.word)s."
    case .noSessions, .compared: return nil
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
  /// The notice for the last complete week at `now`. The same skip rules as below.
  public static func content(sessions: [LoadSession], now: Date, calendar: Calendar, watchHasUnsent: Bool = false) -> Content? {
    content(for: LoadCompare.lastComplete(sessions, unit: .week, now: now, calendar: calendar), watchHasUnsent: watchHasUnsent)
  }

  public struct Content: Equatable {
    public let title: String
    public let body: String
  }

  /// nil = send nothing: an empty week never nags, and nothing goes out in the first weeks, before there is a usual to compare with.
  /// `watchHasUnsent` adds the sync caveat.
  public static func content(for c: LoadCompare, watchHasUnsent: Bool = false) -> Content? {
    guard c.current.sessions > 0, c.state != .firstWeeks else { return nil }
    var body = LoadWords.headline(c, includeUsual: false) + " Tap for what changed."
    if watchHasUnsent { body += " (sync your watch for the full week)" }
    return Content(title: "Your week: \(LoadWords.number(c.current.loadRounded)) load", body: body)
  }

  /// One local notification: when it fires and what it says.
  public struct Scheduled: Equatable {
    public static let identifier = "weekly-summary"
    public let fire: DateComponents
    public let content: Content
  }

  /// Monday 08:00 in the phone's time zone, the first one strictly after `now`.
  public static func nextFire(after now: Date, calendar: Calendar) -> Date? {
    calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)
  }

  /// What to schedule at `now`, or nil for nothing (and cancel the old one). Only when the athlete opted in. The text is the
  /// last complete week as it will stand at the fire time, from the sessions on the phone now, so it is rebuilt on every sync
  /// and every foreground. Sessions still on the watch are not in it.
  public static func plan(sessions: [LoadSession], now: Date, calendar: Calendar, optedIn: Bool, watchHasUnsent: Bool = false) -> Scheduled? {
    guard optedIn, let fire = nextFire(after: now, calendar: calendar) else { return nil }
    let c = LoadCompare.lastComplete(sessions, unit: .week, now: fire, calendar: calendar)
    guard let content = content(for: c, watchHasUnsent: watchHasUnsent) else { return nil }
    return Scheduled(fire: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), content: content)
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
  /// The Monday of the last complete week, the one to judge.
  public let weekStart: Date
  /// Wednesday 28 Oct 2026, noon UTC: the week after `weekStart` is in progress with one session so far.
  public let now: Date
  public let calendar: Calendar
  /// The last complete week against its usual, as the app judges it at `now`.
  public var compare: LoadCompare { LoadCompare.lastComplete(sessions, unit: .week, now: now, calendar: calendar) }
  /// Six weeks ending with the last complete one (what the weekly summary charts).
  public var weeks: [LoadPeriod] { LoadHistory.periods(sessions, unit: .week, ending: weekStart, count: 6, calendar: calendar) }
  /// Six weeks ending with the week in progress (`isCurrent`, so far), what the Home card and History show.
  public var weeksSoFar: [LoadPeriod] { LoadHistory.weeks(sessions, now: now, count: 6, calendar: calendar) }
}

public extension TrainingLoad {
  /// Monday 19 Oct 2026, 00:00 UTC, the start of the week the samples judge.
  static let sampleWeekStartEpoch: TimeInterval = 1_792_368_000

  static var sampleCalendar: Calendar { LoadHistory.calendar(timeZone: TimeZone(identifier: "UTC")!) }

  enum SampleKind { case full, half, focus }
  enum SampleHeartRate { case full, mixed, none }

  private static func sampleLoad(_ kind: SampleKind, _ hr: SampleHeartRate) -> SessionLoad {
    let coverage: Double = hr == .full ? 1 : hr == .mixed ? 0.5 : 0
    switch kind {
    case .full: return SessionLoad(load: 240, minutes: 60, hardMinutes: 28 * coverage, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: coverage)
    case .half: return SessionLoad(load: 120, minutes: 30, hardMinutes: 12 * coverage, simKm: 4, wallBallReps: 0, stationMetres: 1_180, coverage: coverage)
    case .focus: return SessionLoad(load: 100, minutes: 28, hardMinutes: 10 * coverage, simKm: 3, wallBallReps: 150, stationMetres: 0, coverage: coverage)
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
    // One session so far in the week in progress (Tue 27 Oct, 10:00 UTC), so the week card has something to show.
    let soFar = cal.date(byAdding: .day, value: 8, to: monday)!.addingTimeInterval(10 * 3_600)
    out.append(LoadSession(id: "sample-so-far", date: soFar, type: .fullSim, load: sampleLoad(.full, hr)))
    let now = cal.date(byAdding: .day, value: 9, to: monday)!.addingTimeInterval(12 * 3_600)
    return LoadSampleData(sessions: out, weekStart: monday, now: now, calendar: cal)
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
