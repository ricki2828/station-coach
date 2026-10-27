import XCTest
@testable import CoachKit

final class CoachFactsTests: XCTestCase {
  private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  /// `backend/tests/fixtures/coach_facts.json`, which the backend's own tests validate against its schema.
  private func backendFixture() throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("backend/tests/fixtures/coach_facts.json"))
  }

  private func session(until: Int? = nil) -> CoachResult {
    let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .halfSim)
    var t: Int64 = 1_792_836_000_000
    var splits: [StepSplit] = []
    for step in plan.steps {
      if let until, step.index >= until { break }
      let d = Int64(step.targetSeconds + 10) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    return CoachResult(plan: plan, splits: splits, early: until != nil, repTimesMs: [], repCorrection: 0,
                       startedAtEpochMs: 1_792_836_000_000, endedAtEpochMs: t)
  }

  func testBackendFixtureDecodesAndKeepsTheSameKeys() throws {
    let data = try backendFixture()
    let facts = try JSONDecoder().decode(CoachFacts.self, from: data)
    XCTAssertEqual(facts.steps[1].actualSeconds, nil)
    XCTAssertTrue(facts.steps[1].skipped)
    let keys = Set(try (JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
    XCTAssertEqual(keys, CoachFacts.allowedKeys)
    // Round trip: nothing is added or dropped.
    let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(facts)) as! [String: Any]
    XCTAssertEqual(Set(again.keys), keys)
  }

  func testEncodedFactsOnlyUseAllowedKeysAtEveryDepth() throws {
    let facts = CoachFacts.make(from: session(), installId: "i", consentVersion: 1, calendar: utc)
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(facts)) as! [String: Any]
    XCTAssertTrue(Set(obj.keys).isSubset(of: CoachFacts.allowedKeys))
    for s in obj["steps"] as! [[String: Any]] {
      XCTAssertTrue(Set(s.keys).isSubset(of: ["activity", "targetSeconds", "actualSeconds", "skipped"]))
    }
    if let wb = obj["wallBalls"] as? [String: Any] {
      XCTAssertEqual(Set(wb.keys), ["reps", "noReps", "setSizes", "restSeconds"])
    }
  }

  func testNoHeartRateNamesOrTimeOfDay() throws {
    let facts = CoachFacts.make(from: session(), installId: "i", consentVersion: 1, calendar: utc)
    let json = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self).lowercased()
    for banned in ["hr", "heart", "bpm", "name", "email", "latitude", "location", "imu", "note"] {
      XCTAssertFalse(json.contains("\"\(banned)"), banned)
    }
    XCTAssertEqual(facts.date, "2026-10-24")
    XCTAssertEqual(facts.date.count, 10)
  }

  func testFullSessionListsEveryStepWithTimes() {
    let r = session()
    let facts = CoachFacts.make(from: r, installId: "i", consentVersion: 1, calendar: utc)
    XCTAssertEqual(facts.steps.count, r.plan.steps.count)
    XCTAssertTrue(facts.steps.allSatisfy { !$0.skipped && $0.actualSeconds != nil })
    XCTAssertEqual(facts.totalSeconds, r.totalSeconds)
    XCTAssertEqual(facts.plannedSeconds, r.plan.plannedSeconds)
    XCTAssertFalse(facts.early)
    XCTAssertEqual(facts.reference, .plan)
    XCTAssertEqual(facts.referenceDeltaSeconds, r.deltaSeconds)
  }

  func testEarlySessionStopsAtTheLastFinishedStepAndSendsNoComparison() {
    let facts = CoachFacts.make(from: session(until: 5), installId: "i", consentVersion: 1, calendar: utc)
    XCTAssertTrue(facts.early)
    XCTAssertEqual(facts.steps.count, 5)
    XCTAssertNil(facts.reference)
    XCTAssertNil(facts.referenceDeltaSeconds)
  }

  func testSkippedStepHasNoActualSecondsAndNeverZero() throws {
    var r = session()
    r.splits.removeAll { $0.stepIndex == 3 }   // step 3 was never done, a later one was
    let facts = CoachFacts.make(from: r, installId: "i", consentVersion: 1, calendar: utc)
    let skipped = facts.steps[3]
    XCTAssertTrue(skipped.skipped)
    XCTAssertNil(skipped.actualSeconds)
    let steps = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(facts)) as! [String: Any])["steps"] as! [[String: Any]]
    XCTAssertNil(steps[3]["actualSeconds"])
  }

  func testWallBallsCarryRepsSetsAndRests() {
    var r = session()
    let wb = r.plan.steps.first { $0.activity == .wallBalls }!
    let start = r.splits.first { $0.stepIndex == wb.index }!.startMs
    r.repTimesMs = (0..<30).map { i in start + 1_000 + Int64(i) * 2_000 + (i >= 15 ? 12_000 : 0) }
    let facts = CoachFacts.make(from: r, installId: "i", consentVersion: 1, calendar: utc)
    XCTAssertEqual(facts.wallBalls?.reps, 30)
    XCTAssertEqual(facts.wallBalls?.setSizes, [15, 15])
    XCTAssertEqual(facts.wallBalls?.restSeconds.count, 1)
  }
}
