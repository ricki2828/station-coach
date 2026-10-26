import XCTest
@testable import CoachKit

final class CoachResultTests: XCTestCase {
  private let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)

  /// `repTimes` are relative to the wall-ball step's start.
  /// A result where each step took its target plus `extra[stepIndex]` seconds; nil `until` = all steps done.
  private func result(extra: [Int: Int] = [:], until: Int? = nil, repTimes: [Int64] = []) -> CoachResult {
    var t: Int64 = 0
    var splits: [StepSplit] = []
    for step in plan.steps {
      if let until, step.index >= until { break }
      let d = Int64(step.targetSeconds + (extra[step.index] ?? 0)) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    let wbStart = splits.first { plan.steps[$0.stepIndex].activity == .wallBalls }?.startMs ?? 0
    return CoachResult(plan: plan, splits: splits, early: until != nil, repTimesMs: repTimes.map { $0 + wbStart }, repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: t)
  }

  /// 100 reps 2 s apart in the plan's sets, with `rest` seconds between sets.
  private func reps(rest: Int) -> [Int64] {
    var t: Int64 = 1_000
    var out: [Int64] = []
    for size in Stations.wallBallSets(reps: 100) {
      for _ in 0..<size { out.append(t); t += 2_000 }
      t += Int64(rest - 2) * 1000
    }
    return out
  }

  func testRule1RunSlowdownNamesTheStationBefore() {
    // run 3 is step 4, after the sled push (step 3)
    let i = InsightPicker.pick(result(extra: [4: 45]))
    XCTAssertEqual(i.rule, 1)
    XCTAssertEqual(i.headline, "Your run after the sled push was 27\u{00A0}s slower than run 1")
  }

  func testRule1PicksTheBiggestSlowdown() {
    let i = InsightPicker.pick(result(extra: [2: 25, 8: 60]))
    XCTAssertEqual(i.headline, "Your run after the burpee broad jumps was 42\u{00A0}s slower than run 1")
  }

  func testChangeoverTimeAloneIsNotASlowdown() {
    // Run 3 takes 30 s over target: 18 s of that is the changeover, so only 12 s of fade, under the 20 s bar.
    let i = InsightPicker.pick(result(extra: [4: 30]))
    XCTAssertNotEqual(i.rule, 1)
  }

  func testRule2StationOverPlan() {
    let i = InsightPicker.pick(result(extra: [5: 41])) // sled pull
    XCTAssertEqual(i.rule, 2)
    XCTAssertEqual(i.headline, "Sled pull was 0:41 over plan")
  }

  func testRule3WallBallRest() {
    let r = result(repTimes: reps(rest: 20))
    let i = InsightPicker.pick(r)
    XCTAssertEqual(i.rule, 3)
    XCTAssertEqual(i.headline, "You rested 2:00 in wall balls, 30% of the station")
  }

  func testFallbackIsPlainTotal() {
    let i = InsightPicker.pick(result(repTimes: reps(rest: 2)))
    XCTAssertEqual(i.rule, 0)
    XCTAssertEqual(i.headline, "1:20:00 against a 1:20:00 plan")
  }

  func testPartialSessionRowsAreNilNotZero() {
    let r = result(until: 10)
    XCTAssertEqual(r.rows.count, 16)
    XCTAssertNotNil(r.rows[9].actualSeconds)
    XCTAssertNil(r.rows[10].actualSeconds)
    XCTAssertNil(r.rows[15].deltaSeconds)
    XCTAssertEqual(r.completedStationCount, 5)
    XCTAssertEqual(r.shortTitle, "Full sim, 5 of 8 stations")
  }

  func testBestAndWorstStation() {
    let r = result(extra: [1: -25, 5: 41])
    XCTAssertEqual(r.bestWorstStations.best?.0, "SkiErg")
    XCTAssertEqual(r.bestWorstStations.best?.1, -25)
    XCTAssertEqual(r.bestWorstStations.worst?.0, "Sled pull")
    XCTAssertEqual(r.bestWorstStations.worst?.1, 41)
  }

  func testWallBallSetsAndRest() {
    let sets = WallBallAnalysis.sets(repTimesMs: reps(rest: 20), structure: Stations.wallBallSets(reps: 100))
    XCTAssertEqual(sets.map(\.reps), [15, 15, 15, 15, 15, 15, 10])
    XCTAssertEqual(sets.map(\.restBeforeSeconds), [0, 20, 20, 20, 20, 20, 20])
    XCTAssertEqual(WallBallAnalysis.totalRestSeconds(sets), 120)
  }

  func testUncountedRepsLeaveAShortLastSet() {
    let sets = WallBallAnalysis.sets(repTimesMs: Array(reps(rest: 20).prefix(40)), structure: [15, 15, 15, 15])
    XCTAssertEqual(sets.map(\.reps), [15, 15, 10])
  }

  func testRepsOutsideTheWallBallWindowAreIgnored() {
    var r = result(repTimes: reps(rest: 20))
    r.repTimesMs.insert(5, at: 0) // a stray rep during the first run
    XCTAssertEqual(r.wallBallSets().map(\.reps), [15, 15, 15, 15, 15, 15, 10])
  }

  func testRoundTripsThroughJSON() throws {
    let r = result(repTimes: reps(rest: 20))
    let back = try JSONDecoder().decode(CoachResult.self, from: JSONEncoder().encode(r))
    XCTAssertEqual(back, r)
  }
}
