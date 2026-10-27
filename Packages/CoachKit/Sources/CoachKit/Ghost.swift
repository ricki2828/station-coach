import Foundation

/// What the live delta is measured against. One reference per session: the plan, or the last comparable session (the ghost).
public enum DeltaReference: Equatable {
  case plan
  /// `name` completes "your last ...": "sim" or "session".
  case last(name: String)

  /// The band's tag.
  public var tag: String {
    switch self {
    case .plan: return "PLAN"
    case .last: return "LAST"
    }
  }

  /// "plan" / "your last sim", for the voice and for VoiceOver.
  public var phrase: String {
    switch self {
    case .plan: return "plan"
    case .last(let name): return "your last \(name)"
    }
  }
}

/// The delta in words ("0:32 DOWN"), so a sign never has to be learned. Down = behind (amber), up = ahead.
public enum DeltaWords {
  /// Inside this many seconds the band says LEVEL.
  public static let levelSeconds = 3

  public static func isLevel(_ seconds: Int) -> Bool { abs(seconds) < levelSeconds }

  /// "0:32 DOWN" / "0:12 UP" / "LEVEL".
  public static func band(_ seconds: Int) -> String {
    if isLevel(seconds) { return "LEVEL" }
    return "\(Fmt.gap(seconds)) \(seconds > 0 ? "DOWN" : "UP")"
  }

  /// Wrist down the display refreshes once a minute: whole minutes only.
  public static func bandDimmed(_ seconds: Int) -> String {
    let m = Int((Double(abs(seconds)) / 60).rounded())
    if isLevel(seconds) || m == 0 { return "LEVEL" }
    return "\(m) MIN \(seconds > 0 ? "DOWN" : "UP")"
  }

  /// "32 seconds behind plan" / "12 seconds ahead of your last sim" / "level with plan".
  public static func accessibility(_ seconds: Int, reference: DeltaReference) -> String {
    if isLevel(seconds) { return "Level with \(reference.phrase)" }
    return "\(Fmt.spoken(seconds)) \(seconds > 0 ? "behind" : "ahead of") \(reference.phrase)"
  }
}

/// What the Plan tab shows for "Race against": the last comparable session, or why there is none.
public struct GhostOffer: Equatable {
  public var available: Bool
  /// "Last half sim"
  public var title: String
  /// "Sat 24 Oct · 41:12" or the reason there is no ghost.
  public var sub: String
  /// Per-step seconds of the ghost, one per plan step; nil when none.
  public var splits: [Int]?

  public init(available: Bool, title: String, sub: String, splits: [Int]? = nil) {
    self.available = available
    self.title = title
    self.sub = sub
    self.splits = splits
  }

  public static let none = GhostOffer(available: false, title: "Last session", sub: "Finish one to race it")
}

public enum Ghost {
  /// "sim" for the simulations, "session" for the wall-ball focus: completes "your last ...".
  public static func name(_ type: SessionType) -> String { type == .wallBallFocus ? "session" : "sim" }

  /// Seconds each step took, in plan order. Nil when any step has no recorded end, or the splits do not line up with the
  /// plan (a skipped or never-started step has no seconds, and so cannot be raced).
  public static func stepSeconds(_ r: CoachResult) -> [Int]? {
    guard r.splits.count == r.plan.steps.count else { return nil }
    var out: [Int] = []
    for (i, s) in r.splits.enumerated() {
      guard s.stepIndex == i, let end = s.endMs, end >= s.startMs else { return nil }
      out.append(Int((end - s.startMs) / 1000))
    }
    return out
  }

  /// A session that can be raced against `plan`: same type, same step structure (same wall-ball reps), finished
  /// (never ended early, never a skipped step: it would not be comparable).
  public static func isEligible(_ r: CoachResult, for plan: SessionPlan) -> Bool {
    guard r.plan.type == plan.type, !r.early, r.plan.steps.count == plan.steps.count, stepSeconds(r) != nil else { return false }
    return zip(r.plan.steps, plan.steps).allSatisfy { $0.activity == $1.activity && $0.reps == $1.reps }
  }

  /// The newest eligible session, and the newest same-type session if it was passed over (so the phone can say why).
  public static func pick(for plan: SessionPlan, from records: [SessionRecord]) -> (chosen: SessionRecord?, passedOver: SessionRecord?) {
    let sameType = SessionRecord.sorted(records.filter { $0.result.plan.type == plan.type })
    let chosen = sameType.first { isEligible($0.result, for: plan) }
    guard let newest = sameType.first, newest.id != chosen?.id else { return (chosen, nil) }
    return (chosen, newest)
  }

  /// The Plan-tab offer for `plan`. `calendar` fixes the zone the dates are written in.
  public static func offer(for plan: SessionPlan, records: [SessionRecord], calendar: Calendar = .current) -> GhostOffer {
    let noun = plan.type.title.lowercased()
    let title = "Last \(noun)"
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "EEE d MMM"
    let (chosen, passedOver) = pick(for: plan, from: records)
    guard let chosen, let splits = stepSeconds(chosen.result) else {
      let sub = passedOver == nil ? "Finish one \(noun) to race it" : "No complete \(noun) yet"
      return GhostOffer(available: false, title: title, sub: sub)
    }
    let racing = "\(f.string(from: chosen.date)) \u{00B7} \(Fmt.clock(splits.reduce(0, +)))"
    guard let passedOver else { return GhostOffer(available: true, title: title, sub: racing, splits: splits) }
    let why = passedOver.result.early ? "ended early" : "isn't comparable"
    return GhostOffer(available: true, title: title, sub: "\(f.string(from: passedOver.date)) \(why). Racing \(racing)", splits: splits)
  }

  /// `plan` raced against the offer's ghost, or unchanged when `race` is off or there is no ghost.
  public static func plan(_ plan: SessionPlan, racing offer: GhostOffer, race: Bool) -> SessionPlan {
    var p = plan
    p.ghostSplits = (race && offer.available && offer.splits?.count == plan.steps.count) ? offer.splits : nil
    return p
  }

  /// "vs your last half sim: 0:48 faster", for a session that raced a ghost; nil otherwise.
  public static func comparisonLine(_ r: CoachResult) -> String? {
    guard !r.early, let ghostTotal = r.plan.validGhostSplits?.reduce(0, +) else { return nil }
    let d = r.totalSeconds - ghostTotal
    let tail = DeltaWords.isLevel(d) ? "level" : "\(Fmt.gap(d)) \(d < 0 ? "faster" : "slower")"
    return "vs your last \(r.plan.type.title.lowercased()): \(tail)"
  }
}
