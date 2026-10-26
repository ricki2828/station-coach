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
    let sets = WallBallAnalysis.sets(repTimesMs: reps(rest: 20))
    XCTAssertEqual(sets.map(\.reps), [15, 15, 15, 15, 15, 15, 10])
    XCTAssertEqual(sets.map(\.restBeforeSeconds), [0, 20, 20, 20, 20, 20, 20])
    XCTAssertEqual(WallBallAnalysis.totalRestSeconds(sets), 120)
  }

  func testSetsFollowTheAthleteNotThePlan() {
    // 12 reps, rest, 12 reps, rest, 9 reps: not the planned 15s
    var t: Int64 = 0
    var times: [Int64] = []
    for size in [12, 12, 9] {
      for _ in 0..<size { times.append(t); t += 3_000 }
      t += 17_000
    }
    let sets = WallBallAnalysis.sets(repTimesMs: times)
    XCTAssertEqual(sets.map(\.reps), [12, 12, 9])
    XCTAssertEqual(sets.map(\.restBeforeSeconds), [0, 20, 20])
  }

  func testNoRepsNoSets() {
    XCTAssertEqual(WallBallAnalysis.sets(repTimesMs: []), [])
  }

  func testUncountedRepsLeaveAShortLastSet() {
    let sets = WallBallAnalysis.sets(repTimesMs: Array(reps(rest: 20).prefix(40)))
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

  // MARK: No-reps

  private func withNoReps(_ sets: [Int], correction: Int? = nil, repTimes: [Int64]? = nil) -> CoachResult {
    var r = result(repTimes: repTimes ?? reps(rest: 2))
    r.noReps = sets.enumerated().map { NoRepEvent(tMs: Int64($0.offset) * 1000, setIndex: $0.element) }
    r.wallBallCorrection = correction.map { WallBallCorrection(validReps: $0 - sets.count, noReps: sets.count) }
    return r
  }

  func testOldFilesDecodeWithoutNoReps() throws {
    let json = try JSONEncoder().encode(result())
    var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    obj.removeValue(forKey: "noReps")
    obj.removeValue(forKey: "wallBallCorrection")
    let old = try JSONSerialization.data(withJSONObject: obj)
    let back = try JSONDecoder().decode(CoachResult.self, from: old)
    XCTAssertEqual(back.noReps, [])
    XCTAssertNil(back.wallBallCorrection)
  }

  func testNoRepsRoundTrip() throws {
    var r = withNoReps([1, 5, 5])
    r.wallBallCorrection = WallBallCorrection(validReps: 98, noReps: 4)
    let back = try JSONDecoder().decode(CoachResult.self, from: JSONEncoder().encode(r))
    XCTAssertEqual(back, r)
    XCTAssertEqual(back.wallBallCorrection, WallBallCorrection(validReps: 98, noReps: 4))
  }

  func testDerivedStats() {
    let r = withNoReps([1, 5, 5])
    XCTAssertEqual(r.totalThrows, 100)
    XCTAssertEqual(r.noRepCount, 3)
    XCTAssertEqual(r.validReps, 97)
    XCTAssertEqual(r.noRepsBySet(), [0, 1, 0, 0, 0, 2, 0])
  }

  func testPhoneCorrectionReplacesBothCounts() {
    var r = withNoReps([2])
    r.wallBallCorrection = WallBallCorrection(validReps: 100, noReps: 4)
    XCTAssertEqual(r.validReps, 100)
    XCTAssertEqual(r.noRepCount, 4)
    XCTAssertEqual(r.totalThrows, 104)
    r.wallBallCorrection = nil
    r.repCorrection = -2
    XCTAssertEqual(r.validReps, 99 - 2)
  }

  func testEarlyBuildTotalThrowsCorrectionStillDecodes() throws {
    let r = withNoReps([1, 2])
    var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    obj["wallBallCorrection"] = 103
    let back = try JSONDecoder().decode(CoachResult.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertEqual(back.wallBallCorrection, WallBallCorrection(validReps: 101, noReps: 2))
    XCTAssertEqual(back.totalThrows, 103)
  }

  func testEventsWithoutStepIndexBelongToTheFirstWallBallStep() throws {
    let r = withNoReps([1])
    let wb = try XCTUnwrap(plan.steps.first { $0.activity == .wallBalls }).index
    XCTAssertEqual(r.noReps(inStep: wb).count, 1)
    XCTAssertEqual(r.noReps(inStep: wb + 1).count, 0)
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.noReps[0])) as? [String: Any]
    XCTAssertNil(obj?["stepIndex"])
  }

  func testSetIndexForRepsDone() {
    let sets = [15, 15, 15]
    XCTAssertEqual(WallBallProgress.setIndex(repsDone: 0, sets: sets), 0)
    XCTAssertEqual(WallBallProgress.setIndex(repsDone: 15, sets: sets), 0)
    XCTAssertEqual(WallBallProgress.setIndex(repsDone: 16, sets: sets), 1)
    XCTAssertEqual(WallBallProgress.setIndex(repsDone: 99, sets: sets), 2)
    XCTAssertEqual(WallBallProgress.setIndex(repsDone: 5, sets: []), 0)
  }

  func testRule4LateNoRepsNamesTheSetBeforeTheCluster() {
    // 7 sets: the last third is sets 6 and 7 (indices 5, 6)
    let i = InsightPicker.pick(withNoReps([5, 6, 6]))
    XCTAssertEqual(i.rule, 4)
    XCTAssertEqual(i.headline, "Your no-reps came late: 3 after set 5. Depth fades when you tire.")
  }

  func testRule4IgnoresACorrectedCount() {
    var r = withNoReps([5, 6, 6])
    r.wallBallCorrection = WallBallCorrection(validReps: 97, noReps: 5)
    XCTAssertEqual(InsightPicker.pick(r).rule, 0)
  }

  func testRule4NeedsTwoThirdsLate() {
    XCTAssertEqual(InsightPicker.pick(withNoReps([0, 1, 5, 6])).rule, 0) // 2 of 4 late
    XCTAssertEqual(InsightPicker.pick(withNoReps([5, 6])).rule, 0) // under 3
    XCTAssertEqual(InsightPicker.pick(withNoReps([1, 5, 6, 6])).rule, 4) // 3 of 4 late
  }

  func testRule4YieldsToWallBallRest() {
    XCTAssertEqual(InsightPicker.pick(withNoReps([5, 6, 6], repTimes: reps(rest: 20))).rule, 3)
  }

  func testRule4YieldsToHigherRules() {
    var r = withNoReps([5, 6, 6])
    r = CoachResult(plan: r.plan, splits: result(extra: [4: 45]).splits, early: false, repTimesMs: r.repTimesMs, repCorrection: 0,
                    startedAtEpochMs: 0, endedAtEpochMs: r.endedAtEpochMs, noReps: r.noReps)
    XCTAssertEqual(InsightPicker.pick(r).rule, 1)
  }

  func testRule4WorksPerWallBallStep() throws {
    let focus = PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus)
    let wb = focus.steps.filter { $0.activity == .wallBalls }
    XCTAssertGreaterThanOrEqual(wb.count, 2)
    let second = wb[1]
    let late = (second.sets.count * 2 + 2) / 3
    let events = (0..<3).map { NoRepEvent(tMs: Int64($0), setIndex: late, stepIndex: second.index) }
    let r = CoachResult(plan: focus, splits: [], early: true, repTimesMs: [], repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: 0, noReps: events)
    XCTAssertEqual(InsightPicker.pick(r).rule, 4)
    XCTAssertEqual(r.noRepsBySet(step: second.index)[late], 3)
    XCTAssertEqual(r.noRepsBySet(step: wb[0].index).reduce(0, +), 0)
    // The same taps spread over two blocks are not a late cluster in either.
    let split = [events[0], events[1], NoRepEvent(tMs: 3, setIndex: late, stepIndex: wb[0].index)]
    let r2 = CoachResult(plan: focus, splits: [], early: true, repTimesMs: [], repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: 0, noReps: split)
    XCTAssertNotEqual(InsightPicker.pick(r2).rule, 4)
  }

  func testSaveCorrectionPersistsToCoachJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = withNoReps([1, 5, 5])
    try JSONEncoder().encode(r).write(to: dir.appendingPathComponent(CoachResult.fileName))
    try CoachResult.saveCorrection(WallBallCorrection(validReps: 95, noReps: 5), inSessionFolder: dir)
    let back = try JSONDecoder().decode(CoachResult.self, from: Data(contentsOf: dir.appendingPathComponent(CoachResult.fileName)))
    XCTAssertEqual(back.validReps, 95)
    XCTAssertEqual(back.noRepCount, 5)
    XCTAssertEqual(back.plan, r.plan)
    XCTAssertEqual(back.repTimesMs, r.repTimesMs)
  }
}
