import Foundation

/// The whole payload the AI coach service accepts, and nothing else. It matches `backend/openapi.yaml` (`CoachFacts`):
/// times, splits, reps, delta, session type and division. No heart rate, no motion data, no names, no free text.
/// Optional fields are left out of the JSON when nil, never sent as null or 0.
public struct CoachFacts: Codable, Equatable {
  public struct Step: Codable, Equatable {
    public let activity: Activity
    public let targetSeconds: Int
    /// Absent for a skipped or quit step. Never 0.
    public let actualSeconds: Int?
    public let skipped: Bool
    /// Present (true) only for the step that was started and abandoned when the session ended early.
    public let quit: Bool?
  }

  public struct WallBalls: Codable, Equatable {
    public let reps: Int
    public let noReps: Int
    public let setSizes: [Int]
    public let restSeconds: [Int]
  }

  public enum Reference: String, Codable, Equatable { case plan, ghost }

  public let consentVersion: Int
  public let installId: String
  /// Day only, "2026-10-27".
  public let date: String
  public let sessionType: SessionType
  public let division: Division
  public let raceTargetSeconds: Int
  public let totalSeconds: Int
  public let plannedSeconds: Int
  public let early: Bool
  public let steps: [Step]
  public let wallBalls: WallBalls?
  public let fadeSeconds: Int?
  public let reference: Reference?
  public let referenceDeltaSeconds: Int?

  /// The top-level keys the service allows. A test compares the encoded JSON against this and the backend fixture.
  public static let allowedKeys: Set<String> = [
    "consentVersion", "installId", "date", "sessionType", "division", "raceTargetSeconds", "totalSeconds", "plannedSeconds",
    "early", "steps", "wallBalls", "fadeSeconds", "reference", "referenceDeltaSeconds",
  ]

  private static let maxSeconds = 36_000

  private static func clamp(_ v: Int, _ hi: Int = maxSeconds) -> Int { min(max(0, v), hi) }

  /// The same facts under another consent version (queued items are re-stamped when the athlete re-consents).
  public func withConsentVersion(_ v: Int) -> CoachFacts {
    CoachFacts(consentVersion: v, installId: installId, date: date, sessionType: sessionType, division: division,
               raceTargetSeconds: raceTargetSeconds, totalSeconds: totalSeconds, plannedSeconds: plannedSeconds, early: early,
               steps: steps, wallBalls: wallBalls, fadeSeconds: fadeSeconds, reference: reference,
               referenceDeltaSeconds: referenceDeltaSeconds)
  }

  /// Facts for one finished session. `calendar` decides which day the session belongs to.
  public static func make(from result: CoachResult, installId: String, consentVersion: Int, calendar: Calendar = .current) -> CoachFacts {
    let rows = result.rows
    // An early session's last started step was quit, not completed, even if the watch closed its split: it is sent
    // as quit with no time. Steps before it that were not done are skipped.
    let quitIndex = result.early ? result.splits.max { $0.startMs < $1.startMs }?.stepIndex : nil
    let lastIncluded = result.early ? rows.lastIndex { $0.actualSeconds != nil || $0.step.index == quitIndex } : rows.indices.last
    let included = lastIncluded.map { Array(rows[...$0]) } ?? []
    let steps = included.map { r -> Step in
      let isQuit = r.step.index == quitIndex
      let done = r.actualSeconds != nil && !isQuit
      return Step(activity: r.step.activity, targetSeconds: clamp(r.step.targetSeconds), actualSeconds: done ? r.actualSeconds.map { clamp($0) } : nil,
                  skipped: !done && !isQuit, quit: isQuit ? true : nil)
    }

    var wallBalls: WallBalls?
    let sets = result.wallBallSets()
    if !sets.isEmpty {
      wallBalls = WallBalls(
        reps: min(result.validReps, 500), noReps: min(result.noRepCount, 500),
        setSizes: Array(sets.map { min($0.reps, 500) }.prefix(60)),
        restSeconds: Array(sets.dropFirst().map { clamp($0.restBeforeSeconds, 3600) }.prefix(60)))
    }

    let date = Date(timeIntervalSince1970: Double(result.startedAtEpochMs) / 1000)
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    let day = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)

    let delta = result.early ? nil : max(-maxSeconds, min(maxSeconds, result.deltaSeconds))
    return CoachFacts(
      consentVersion: consentVersion, installId: installId, date: day, sessionType: result.plan.type, division: result.plan.division,
      raceTargetSeconds: clamp(result.plan.raceTargetSeconds), totalSeconds: clamp(result.totalSeconds),
      plannedSeconds: clamp(included.reduce(0) { $0 + $1.step.targetSeconds }), early: result.early, steps: steps,
      wallBalls: wallBalls, fadeSeconds: RunFade.fade(result).map { max(-3600, min(3600, $0)) },
      reference: delta == nil ? nil : .plan, referenceDeltaSeconds: delta)
  }
}
