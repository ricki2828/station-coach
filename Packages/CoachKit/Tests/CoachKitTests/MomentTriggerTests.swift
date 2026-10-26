import XCTest
@testable import CoachKit

final class MomentTriggerTests: XCTestCase {
  private func record(_ id: String, _ type: SessionType = .fullSim, day: Int64, fade: Int, total: Int = 0) -> SessionRecord {
    let plan = PlanBuilder.build(division: .openMen, target: 5400, type: type)
    var t: Int64 = 0
    var splits: [StepSplit] = []
    for step in plan.steps {
      var extra = total
      if step.isRun, (step.runNumber ?? 0) > 1 { extra += fade + plan.transitionSeconds }
      let d = Int64(step.targetSeconds + extra) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    let start = (1_792_836_000 + day * 86_400) * 1000
    return SessionRecord(id: id, result: CoachResult(plan: plan, splits: splits, early: false, repTimesMs: [], repCorrection: 0,
                                                      startedAtEpochMs: start, endedAtEpochMs: start + t))
  }

  func testFirstSessionEarnsAMomentOnce() {
    let a = record("a", day: 0, fade: 27)
    let first = MomentTrigger.evaluate(records: [a], seen: [])
    XCTAssertEqual(first.outcome?.moment, .first(.fullSim))
    XCTAssertEqual(first.markSeen, ["a"])
    XCTAssertNil(MomentTrigger.evaluate(records: [a], seen: ["a"]).outcome)
  }

  func testBurstShowsOnlyOneAndMarksOlderSeen() {
    let a = record("a", day: 0, fade: 27)
    let b = record("b", .halfSim, day: 1, fade: 20)
    let r = MomentTrigger.evaluate(records: [a, b], seen: [])
    XCTAssertEqual(r.outcome?.record.id, "b")
    XCTAssertEqual(r.markSeen, ["a", "b"])
  }

  func testNoMomentStillMarksSeen() {
    let a = record("a", day: 0, fade: 27)
    let b = record("b", day: 1, fade: 26, total: 10)
    let r = MomentTrigger.evaluate(records: [a, b], seen: ["a"])
    XCTAssertNil(r.outcome)
    XCTAssertEqual(r.markSeen, ["b"])
  }

  func testBestCarriesTheEarlierDate() {
    let a = record("a", day: 0, fade: 27, total: 10)
    let b = record("b", day: 7, fade: 27, total: 0)
    let r = MomentTrigger.evaluate(records: [a, b], seen: ["a"])
    guard case .best(.fullSim, let prev)? = r.outcome?.moment else { return XCTFail("expected best") }
    XCTAssertEqual(prev, a.result.totalSeconds)
    XCTAssertEqual(r.outcome?.previousBestDate, a.date)
  }

  func testNothingUnseenIsNil() {
    let r = MomentTrigger.evaluate(records: [], seen: [])
    XCTAssertNil(r.outcome)
    XCTAssertTrue(r.markSeen.isEmpty)
  }
}
