import Foundation

/// One finished coached session as the phone holds it: the folder id plus the watch's `coach.json`.
public struct SessionRecord: Equatable, Identifiable {
  public let id: String
  public let result: CoachResult

  public init(id: String, result: CoachResult) {
    self.id = id
    self.result = result
  }

  public var date: Date { Date(timeIntervalSince1970: Double(result.startedAtEpochMs) / 1000) }
  public var type: SessionType { result.plan.type }
  /// Ran to the end with nothing skipped: only such a session is comparable (a best, a fade, a target line, a ghost).
  public var isComplete: Bool { !result.early && result.skippedStationCount == 0 }
  public var fade: Int? { RunFade.fade(result) }

  /// Newest first.
  public static func sorted(_ records: [SessionRecord]) -> [SessionRecord] {
    records.sorted { $0.result.startedAtEpochMs > $1.result.startedAtEpochMs }
  }

  /// "1:44 over target" / "2:42 under target" / "on target". nil for a partial session: no target line.
  public var targetWords: (text: String, over: Bool)? {
    guard isComplete else { return nil }
    let d = result.totalSeconds - result.plan.plannedSeconds
    if d == 0 { return ("on target", false) }
    return (d > 0 ? "\(Fmt.gap(d)) over target" : "\(Fmt.gap(d)) under target", d > 0)
  }
}

public enum HistoryFormat {
  private static func format(_ pattern: String, _ date: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = pattern
    return f.string(from: date)
  }

  /// "Sat 24 Oct".
  public static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String { format("EEE d MMM", date, timeZone) }
  /// "24 Oct".
  public static func dayMonth(_ date: Date, timeZone: TimeZone = .current) -> String { format("d MMM", date, timeZone) }
  /// "SAT 24 OCT" style is the caller's textCase.
}

/// Run fade: how much slower each run is than run 1, with the changeover taken out of runs 2 and later.
/// Shared by the Home hero, the detail bars and `InsightPicker` rule 1.
public enum RunFade {
  public struct Slowdown: Equatable {
    public let runNumber: Int
    /// Name of the step before the run ("Sled push").
    public let after: String
    public let afterActivity: Activity
    public let seconds: Int
  }

  /// One entry per completed run 2..N, in order. Empty when run 1 or the run is not done.
  public static func slowdowns(_ result: CoachResult) -> [Slowdown] {
    // A session with a skipped station has no fade: "the run after the row" measures nothing when no row was done.
    guard result.skippedStationCount == 0 else { return [] }
    let rows = result.rows
    guard let first = rows.first(where: { $0.step.isRun })?.actualSeconds else { return [] }
    var out: [Slowdown] = []
    for (i, r) in rows.enumerated() where r.step.isRun && (r.step.runNumber ?? 0) > 1 {
      guard let a = r.actualSeconds, i > 0 else { continue }
      // Runs 2-8 start with a changeover that run 1 does not have: that is not fade.
      out.append(Slowdown(runNumber: r.step.runNumber ?? 0, after: rows[i - 1].step.name, afterActivity: rows[i - 1].step.activity, seconds: (a - result.plan.transitionSeconds) - first))
    }
    return out
  }

  // TODO (P3): run 1 is the denominator, so a deliberately easy run 1 inflates the fade. Do not coach "run 1 easy".
  // The planned changeover (`plan.transitionSeconds`) is subtracted, not the measured one, so a slow changeover counts as fade.
  /// Mean slowdown over runs 2..N, in seconds. nil with fewer than 2 runs done.
  public static func fade(_ result: CoachResult) -> Int? {
    let s = slowdowns(result)
    guard !s.isEmpty else { return nil }
    return Int((Double(s.map(\.seconds).reduce(0, +)) / Double(s.count)).rounded())
  }

  /// Within this many seconds counts as steady.
  public static let steadySeconds = 3
}

public struct RaceSetup: Equatable {
  public var division: Division
  public var targetSeconds: Int
  public init(division: Division = .openMen, targetSeconds: Int = 5400) {
    self.division = division
    self.targetSeconds = targetSeconds
  }

  /// "1:30:00 \u{00B7} Open men".
  public var summary: String { "\(Fmt.target(targetSeconds)) \u{00B7} \(division.title)" }
}

public struct Recommendation: Equatable {
  /// Which rule fired, 1...4.
  public let rule: Int
  public let type: SessionType
  public let line: String
  public var ctaTitle: String { "\(type.title) \u{203A}" }

  /// First match wins: no sessions -> half sim; wall-ball trouble last time -> wall-ball focus;
  /// no full sim for 10+ days (or ever) -> full sim; otherwise half sim.
  public static func pick(records: [SessionRecord], now: Date) -> Recommendation {
    let recs = SessionRecord.sorted(records)
    guard let last = recs.first else {
      return Recommendation(rule: 1, type: .halfSim, line: "Start with a half sim. It sets your baseline.")
    }
    let insight = InsightPicker.pick(last.result)
    let rest = WallBallAnalysis.totalRestSeconds(last.result.wallBallSets())
    // Worst station against plan, matched on the activity. A focus session has only wall balls, so any overrun there
    // would always win: after one, the recommendation moves on.
    let worst = last.result.rows.filter { !$0.step.isRun }.compactMap { r in r.deltaSeconds.map { (r.step.activity, $0) } }.max { $0.1 < $1.1 }
    let wbWorst = worst.map { $0.0 == .wallBalls && $0.1 >= InsightPicker.stationOverMin } ?? false
    if last.type != .wallBallFocus, insight.rule == 3 || wbWorst {
      let cost = insight.rule == 3 || rest >= InsightPicker.restSecondsMin
        ? "Your wall balls cost \(Fmt.gap(rest)) in rest."
        : "Wall balls cost you the most against plan."
      return Recommendation(rule: 2, type: .wallBallFocus, line: "\(cost) Wall-ball focus trains sets and breaths.")
    }
    // An abandoned full sim does not reset the 10-day clock.
    let lastFull = recs.first { $0.type == .fullSim && $0.isComplete }
    if lastFull == nil || now.timeIntervalSince(lastFull!.date) >= 10 * 86_400 {
      return Recommendation(rule: 3, type: .fullSim, line: "Time for a full sim. It's the real test of the fade.")
    }
    return Recommendation(rule: 4, type: .halfSim, line: "Half sim: same runs, half the damage.")
  }
}

public enum HomeState: Equatable {
  /// No session with a fade yet.
  case none
  /// Exactly one fade: the baseline.
  case baseline
  case trend(Trend)

  public enum Trend: Equatable { case up, steady, down }
}

public struct HomeModel: Equatable {
  public let state: HomeState
  public let setup: RaceSetup
  public let last: SessionRecord?
  public let next: Recommendation
  /// The last 6 fades, oldest first, with the session type of each.
  public let recent: [Int]
  public let recentTypes: [SessionType]
  public let latestFade: Int?
  /// Session type of the latest complete fade; the hero and the trend are about this type only.
  public let heroType: SessionType?
  /// Fade of the previous complete session of the same type as the latest, and its date.
  public let previousFade: Int?
  public let previousDate: Date?
  /// Run that cost the most in the latest session, "Sled push".
  public let biggestAfter: String?
  public let latestDate: Date?

  public init(records: [SessionRecord], setup: RaceSetup = RaceSetup(), now: Date = Date()) {
    let recs = SessionRecord.sorted(records)
    // Fade is not comparable across types (a full sim averages 7 runs, a half sim 3) or with partials, so the hero,
    // the trend and the baseline use complete sessions only, and the trend compares like with like.
    let withFade = recs.filter(\.isComplete).compactMap { r in r.fade.map { (r, $0) } }
    self.setup = setup
    last = recs.first
    next = Recommendation.pick(records: recs, now: now)
    let recentPairs = Array(withFade.prefix(6).reversed())
    recent = recentPairs.map { max(0, $0.1) }
    recentTypes = recentPairs.map { $0.0.type }
    latestFade = withFade.first?.1
    latestDate = withFade.first?.0.date
    heroType = withFade.first?.0.type
    let prior = withFade.dropFirst().first { $0.0.type == withFade.first?.0.type }
    previousFade = prior?.1
    previousDate = prior?.0.date
    biggestAfter = withFade.first.flatMap { RunFade.slowdowns($0.0.result).max { $0.seconds < $1.seconds }?.after }
    if let latest = latestFade {
      if let prev = previousFade {
        // Clamped like the hero: two runs faster than run 1 both read "0 s", so they are holding, not "more".
        let d = max(0, latest) - max(0, prev)
        state = .trend(d < -RunFade.steadySeconds ? .down : d > RunFade.steadySeconds ? .up : .steady)
      } else {
        state = .baseline
      }
    } else {
      state = .none
    }
  }

  /// Session types behind the bars, in order of first appearance. The bars need a legend when there is more than one.
  public var legendTypes: [SessionType] {
    var seen: [SessionType] = []
    for t in recentTypes where !seen.contains(t) { seen.append(t) }
    return seen
  }

  /// A fade below zero reads "0 s": the line under it says "faster than run 1".
  public static func fadeText(_ s: Int) -> String { "\(max(0, s)) s" }

  /// "YOUR RUN FADE" until there is a number, then the type it belongs to: "HALF SIM FADE".
  public var kicker: String {
    guard let t = heroType else { return "YOUR RUN FADE" }
    return state == .baseline ? "\(t.title.uppercased()) FADE \u{00B7} BASELINE" : "\(t.title.uppercased()) FADE"
  }

  /// Hero text: the statement while there is no number, the fade once there is.
  public var hero: String {
    guard let f = latestFade else { return "FIND YOUR FADE" }
    return Self.fadeText(f)
  }

  /// Line under the hero.
  public var line: String {
    switch state {
    case .none: return "One sim measures how much slower you run after each station. That's the number this app helps you shrink."
    default: return (latestFade ?? 0) < 0 ? "faster than run 1" : "slower per run than run 1"
    }
  }

  public var sub: String? {
    guard state == .baseline, let d = latestDate else { return nil }
    let day = HistoryFormat.shortDate(d)
    if let b = biggestAfter { return "\(day). Biggest after the \(b.lowercased())." }
    return "\(day)."
  }

  /// The chip on the hero card.
  public var chip: String? {
    switch state {
    case .none: return nil
    case .baseline: return "1 \((heroType ?? .fullSim).title.uppercased())"
    case .trend(let t):
      let since = previousDate.map { HistoryFormat.dayMonth($0) } ?? ""
      let diff = abs(max(0, latestFade ?? 0) - max(0, previousFade ?? 0))
      switch t {
      case .down: return "\(diff) s less fade since \(since)"
      case .steady: return "Holding since \(since)"
      case .up: return "\(diff) s more than last time"
      }
    }
  }
}

/// Picks the one phone moment a newly synced session earns, if any.
public enum MomentPicker {
  public static let leastFadeMargin = 3

  /// Complete sessions only: a partial never earns a moment, so "your first full sim" fires once, on the first complete one.
  /// Only sessions that started before `new` count, so a backfilled old session is not judged against the future.
  /// 1. `.best`: an earlier complete session of the same type, and a faster total than all of them.
  /// 2. `.leastFade`: an earlier complete fade of the same type, and this fade at least 3 s below all of them.
  /// 3. `.first`: the first complete session of its type.
  public static func pick(previous: [SessionRecord], new: SessionRecord) -> Moment? {
    guard new.isComplete else { return nil }
    let earlier = previous.filter { $0.id != new.id && $0.result.startedAtEpochMs < new.result.startedAtEpochMs }
    let completeSame = earlier.filter { $0.type == new.type && $0.isComplete }
    if let best = completeSame.map({ $0.result.totalSeconds }).min(), new.result.totalSeconds < best {
      return .best(new.type, previousBest: best)
    }
    // Same type only: fade is not comparable between full, half and wall-ball focus sessions.
    if let fade = new.fade, let low = completeSame.compactMap(\.fade).min(), fade <= low - leastFadeMargin {
      return .leastFade(previous: low)
    }
    return completeSame.isEmpty ? .first(new.type) : nil
  }
}
