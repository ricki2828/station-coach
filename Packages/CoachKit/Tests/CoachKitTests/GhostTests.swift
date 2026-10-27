import XCTest
@testable import CoachKit

final class GhostTests: XCTestCase {
  private let sat24: Int64 = 1_792_843_200_000
  private let sat17: Int64 = 1_792_238_400_000
  private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  private func plan(_ type: SessionType = .halfSim, reps: Int = 50) -> SessionPlan {
    PlanBuilder.build(division: .openMen, target: 5400, type: type, wallBallReps: reps)
  }

  /// A session where every step took its target plus `extra`; `until` cuts it short; `skipLast` leaves the last split open.
  private func record(_ id: String, _ type: SessionType = .halfSim, start: Int64, extra: Int = 0, until: Int? = nil,
                      reps: Int = 50, openLast: Bool = false) -> SessionRecord {
    let p = plan(type, reps: reps)
    var t = start
    var splits: [StepSplit] = []
    for step in p.steps {
      if let until, step.index >= until { break }
      let d = Int64(step.targetSeconds + extra) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    if openLast { splits[splits.count - 1].endMs = nil }
    let r = CoachResult(plan: p, splits: splits, early: until != nil, repTimesMs: [], repCorrection: 0, startedAtEpochMs: start, endedAtEpochMs: t)
    return SessionRecord(id: id, result: r)
  }

  // MARK: Step seconds and eligibility

  func testStepSecondsAreInPlanOrder() throws {
    let r = record("a", start: sat24, extra: 5).result
    let secs = try XCTUnwrap(Ghost.stepSeconds(r))
    XCTAssertEqual(secs, r.plan.steps.map { $0.targetSeconds + 5 })
  }

  func testEarlyOrOpenOrSkippedSessionsHaveNoStepSeconds() {
    XCTAssertNil(Ghost.stepSeconds(record("e", start: sat24, until: 4).result), "ended early: steps missing")
    XCTAssertNil(Ghost.stepSeconds(record("o", start: sat24, openLast: true).result), "last step never ended")
    var skipped = record("s", start: sat24).result
    skipped.splits.remove(at: 3) // a step with no split (skipped): the splits no longer line up with the plan
    XCTAssertNil(Ghost.stepSeconds(skipped))
  }

  func testEligibilityNeedsTheSameTypeAStructureAndACompleteRun() {
    let p = plan(.halfSim)
    XCTAssertTrue(Ghost.isEligible(record("a", start: sat24).result, for: p))
    XCTAssertFalse(Ghost.isEligible(record("e", start: sat24, until: 4).result, for: p), "ended early")
    XCTAssertFalse(Ghost.isEligible(record("f", .fullSim, start: sat24).result, for: p), "another type")
    var early = record("flagged", start: sat24).result
    early.early = true
    XCTAssertFalse(Ghost.isEligible(early, for: p), "early flag alone is enough")
    let wb50 = plan(.wallBallFocus, reps: 50), wb75 = plan(.wallBallFocus, reps: 75)
    XCTAssertTrue(Ghost.isEligible(record("w", .wallBallFocus, start: sat24, reps: 50).result, for: wb50))
    XCTAssertFalse(Ghost.isEligible(record("w", .wallBallFocus, start: sat24, reps: 50).result, for: wb75), "different reps per round")
  }

  // MARK: Picking

  func testPicksTheNewestEligibleAndNotesAPassedOverNewerOne() {
    let p = plan()
    let old = record("old", start: sat17, extra: 10)
    let newer = record("newer", start: sat24, extra: 0)
    XCTAssertEqual(Ghost.pick(for: p, from: [old, newer]).chosen?.id, "newer")
    XCTAssertNil(Ghost.pick(for: p, from: [old, newer]).passedOver)
    let earlyNewest = record("early", start: sat24 + 86_400_000, until: 5)
    let pick = Ghost.pick(for: p, from: [old, newer, earlyNewest])
    XCTAssertEqual(pick.chosen?.id, "newer")
    XCTAssertEqual(pick.passedOver?.id, "early")
  }

  func testNoComparableSessionMeansNoGhost() {
    let p = plan()
    XCTAssertNil(Ghost.pick(for: p, from: []).chosen)
    XCTAssertNil(Ghost.pick(for: p, from: [record("full", .fullSim, start: sat24)]).chosen, "other types ignored")
    let onlyEarly = Ghost.pick(for: p, from: [record("e", start: sat24, until: 3)])
    XCTAssertNil(onlyEarly.chosen)
    XCTAssertEqual(onlyEarly.passedOver?.id, "e")
  }

  // MARK: Offer copy

  func testOfferCopy() {
    let p = plan()
    let none = Ghost.offer(for: p, records: [], calendar: utc)
    XCTAssertFalse(none.available)
    XCTAssertEqual(none.title, "Last half sim")
    XCTAssertEqual(none.sub, "Finish one half sim to race it")
    let ok = Ghost.offer(for: p, records: [record("a", start: sat24)], calendar: utc)
    XCTAssertTrue(ok.available)
    XCTAssertEqual(ok.sub, "Sat 24 Oct \u{00B7} \(Fmt.clock(p.plannedSeconds))")
    XCTAssertEqual(ok.splits?.count, p.steps.count)
    let passed = Ghost.offer(for: p, records: [record("a", start: sat17), record("e", start: sat24, until: 4)], calendar: utc)
    XCTAssertTrue(passed.available)
    XCTAssertEqual(passed.sub, "Sat 24 Oct ended early. Racing Sat 17 Oct \u{00B7} \(Fmt.clock(p.plannedSeconds))")
    let noneComplete = Ghost.offer(for: p, records: [record("e", start: sat24, until: 4)], calendar: utc)
    XCTAssertFalse(noneComplete.available)
    XCTAssertEqual(noneComplete.sub, "No complete half sim yet")
  }

  // MARK: Plan carries the ghost

  func testPlanRacesTheGhostOnlyWhenAskedAndAvailable() {
    let p = plan()
    let offer = Ghost.offer(for: p, records: [record("a", start: sat24, extra: 3)], calendar: utc)
    XCTAssertNil(Ghost.plan(p, racing: offer, race: false).ghostSplits, "plan is the default")
    XCTAssertEqual(Ghost.plan(p, racing: offer, race: true).ghostSplits, offer.splits)
    XCTAssertNil(Ghost.plan(p, racing: .none, race: true).ghostSplits, "nothing to race: back to the plan")
  }

  func testOldPlansWithoutGhostSplitsStillDecodeAndGhostSplitsRoundTrip() throws {
    let p = plan()
    let data = try JSONEncoder().encode(p)
    var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(obj["ghostSplits"], "absent when nil")
    let back = try JSONDecoder().decode(SessionPlan.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertNil(back.ghostSplits)
    XCTAssertEqual(back, p)
    var raced = p
    raced.ghostSplits = p.steps.map { $0.targetSeconds + 1 }
    obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raced)) as? [String: Any])
    XCTAssertNotNil(obj["ghostSplits"])
    XCTAssertEqual(try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(raced)), raced)
  }

  func testAGhostOfTheWrongLengthIsIgnored() {
    var p = plan()
    p.ghostSplits = [10, 20]
    XCTAssertNil(p.validGhostSplits)
    XCTAssertEqual(p.reference, .plan)
    XCTAssertEqual(p.referenceSeconds(at: 0), p.steps[0].targetSeconds)
    XCTAssertEqual(p.referenceSeconds(at: 999), 0, "out of range is not indexed")
  }

  // MARK: Live delta

  private func machine(ghostExtra: Int?) -> SessionMachine {
    var p = plan()
    if let ghostExtra { p.ghostSplits = p.steps.map { $0.targetSeconds + ghostExtra } }
    var m = SessionMachine(plan: p)
    m.start(at: 0)
    return m
  }

  func testDeltaAgainstTheGhostUsesItsStepSecondsAndThePlanDeltaIsUnchanged() {
    // Each step takes exactly its target for 3 steps, so the plan delta is 0 and a ghost 10 s slower per step reads 10 s ahead per step.
    var plain = machine(ghostExtra: nil), ghost = machine(ghostExtra: 10)
    var t: Int64 = 0
    for step in plain.plan.steps.prefix(3) {
      t += Int64(step.targetSeconds) * 1000
      plain.advance(at: t)
      ghost.advance(at: t)
    }
    XCTAssertEqual(plain.deltaSeconds(at: t), 0)
    XCTAssertEqual(ghost.deltaSeconds(at: t), -30)
    XCTAssertEqual(ghost.plan.reference, .last(name: "sim"))
  }

  func testUndoWhileRacingTheGhostRestoresTheEarlierDelta() {
    var m = machine(ghostExtra: 5)
    let first = Int64(m.plan.steps[0].targetSeconds + 20) * 1000 // 15 s behind the ghost on step 0
    m.advance(at: first)
    XCTAssertEqual(m.deltaSeconds(at: first), 15)
    let second = first + Int64(m.plan.steps[1].targetSeconds) * 1000
    m.advance(at: second)
    XCTAssertEqual(m.deltaSeconds(at: second), 15 - 5)
    XCTAssertTrue(m.undo(at: second + 4000))
    XCTAssertEqual(m.deltaSeconds(at: first), 15, "back on step 1: only step 0 counts, as before")
  }

  // MARK: Words and voice

  func testBandWords() {
    XCTAssertEqual(DeltaWords.band(32), "0:32 DOWN")
    XCTAssertEqual(DeltaWords.band(-12), "0:12 UP")
    XCTAssertEqual(DeltaWords.band(641), "10:41 DOWN")
    for level in [0, 2, -2] { XCTAssertEqual(DeltaWords.band(level), "LEVEL") }
    XCTAssertEqual(DeltaWords.band(3), "0:03 DOWN")
    XCTAssertEqual(DeltaWords.bandDimmed(32), "1 MIN DOWN")
    XCTAssertEqual(DeltaWords.bandDimmed(-125), "2 MIN UP")
    XCTAssertEqual(DeltaWords.bandDimmed(20), "LEVEL")
    XCTAssertEqual(DeltaWords.accessibility(32, reference: .plan), "32 seconds behind plan")
    XCTAssertEqual(DeltaWords.accessibility(-12, reference: .last(name: "sim")), "12 seconds ahead of your last sim")
    XCTAssertEqual(DeltaWords.accessibility(1, reference: .plan), "Level with plan")
    XCTAssertEqual(DeltaReference.plan.tag, "PLAN")
    XCTAssertEqual(DeltaReference.last(name: "sim").tag, "LAST")
  }

  func testGhostVoiceLines() {
    let last = DeltaReference.last(name: "sim")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -12, reference: last), "Ten seconds up on your last sim.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -30, reference: last), "Thirty seconds up on your last sim.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: 20, reference: last), "Twenty seconds down on your last sim. Stay calm.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: 4, reference: last), "Level with your last sim.")
    // The plan lines are unchanged.
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -30), "Thirty seconds up on plan.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: 4), "On plan.")
  }

  func testGhostFinishLine() {
    let last = DeltaReference.last(name: "sim")
    XCTAssertEqual(CoachCopy.finish(totalSeconds: 4722, plannedSeconds: 4800, best: nil, worst: nil, early: false, reference: last, referenceTotalSeconds: 4770, sessionName: "full sim"),
                   "1:18:42. 0:48 faster than your last full sim.")
    XCTAssertEqual(CoachCopy.finish(totalSeconds: 4818, plannedSeconds: 4800, best: nil, worst: nil, early: false, reference: last, referenceTotalSeconds: 4770, sessionName: "full sim"),
                   "1:20:18. 0:48 slower than your last full sim.")
    XCTAssertEqual(CoachCopy.finish(totalSeconds: 4771, plannedSeconds: 4800, best: nil, worst: nil, early: false, reference: last, referenceTotalSeconds: 4770, sessionName: "full sim"),
                   "1:19:31. Level with your last full sim.")
    XCTAssertEqual(CoachCopy.finish(totalSeconds: 4722, plannedSeconds: 4800, best: nil, worst: nil, early: false), "1:18:42. 1:18 under target.")
    XCTAssertTrue(CoachCopy.finish(totalSeconds: 2000, plannedSeconds: 4800, best: nil, worst: nil, early: true, reference: last, referenceTotalSeconds: 4770, sessionName: "sim").hasPrefix("33:20."))
  }

  func testComparisonLineOnlyForARacedFinishedSession() {
    var r = record("a", start: sat24, extra: 0).result
    XCTAssertNil(Ghost.comparisonLine(r))
    r.plan.ghostSplits = r.plan.steps.map { $0.targetSeconds + 3 }
    let n = Int(r.plan.steps.count) * 3
    XCTAssertEqual(Ghost.comparisonLine(r), "vs your last half sim: \(Fmt.gap(n)) faster")
    r.early = true
    XCTAssertNil(Ghost.comparisonLine(r))
  }
}
