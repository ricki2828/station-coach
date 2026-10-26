import XCTest
@testable import CoachKit

final class PlanTests: XCTestCase {
  func testFullSimShape() {
    let p = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)
    XCTAssertEqual(p.steps.count, 16)
    XCTAssertEqual(p.steps.map(\.index), Array(0..<16))
    XCTAssertEqual(p.steps.filter(\.isRun).count, 8)
    XCTAssertEqual(p.steps.filter { !$0.isRun }.map(\.activity), Stations.race)
    XCTAssertEqual(p.steps[0].name, "Run 1")
    XCTAssertEqual(p.stationCount, 8)
  }

  func testTargetsSumToTheRaceTarget() {
    let p = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)
    XCTAssertEqual(p.plannedSeconds, 4800)
    XCTAssertEqual(PlanBuilder.build(division: .openMen, target: 5400, type: .fullSim).plannedSeconds, 5400)
    XCTAssertEqual(p.steps[0].targetSeconds, 324) // 288 run + 36 transition allowance
    XCTAssertEqual(p.transitionSeconds, 18)
    let wb = p.steps.last!
    XCTAssertEqual(wb.activity, .wallBalls)
    XCTAssertEqual(wb.targetSeconds, 397)
  }

  func testStationProfileSumsTo100() {
    XCTAssertEqual(PlanBuilder.stationProfile.values.reduce(0, +), 100)
    XCTAssertEqual(PlanBuilder.runShare + PlanBuilder.stationShare + PlanBuilder.transitionShare, 1, accuracy: 1e-9)
  }

  func testHalfSimIsRunsAndStations1to4() {
    let p = PlanBuilder.build(division: .proWomen, target: 4800, type: .halfSim)
    XCTAssertEqual(p.steps.count, 8)
    XCTAssertEqual(p.steps.filter { !$0.isRun }.map(\.activity), Array(Stations.race.prefix(4)))
  }

  func testWallBallFocus() {
    let p = PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus)
    XCTAssertEqual(p.steps.count, 6)
    XCTAssertEqual(p.steps.filter { $0.activity == .wallBalls }.count, 3)
    let wb = p.steps[1]
    XCTAssertEqual(wb.reps, 50)
    XCTAssertEqual(wb.sets, [10, 10, 10, 10, 10])
    XCTAssertEqual(wb.targetSeconds, 199)
  }

  func testWallBallFocusRepsSetting() {
    for reps in PlanBuilder.focusRepOptions {
      let p = PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus, wallBallReps: reps)
      let walls = p.steps.filter { $0.activity == .wallBalls }
      XCTAssertEqual(walls.count, 3)
      for wb in walls {
        XCTAssertEqual(wb.reps, reps)
        XCTAssertEqual(wb.sets.reduce(0, +), reps)
        XCTAssertTrue(wb.sets.dropLast().allSatisfy { $0 == 10 }, "sets of 10 by default")
        XCTAssertEqual(wb.targetSeconds, Int((4800 * 0.46 * 0.18 * Double(reps) / 100).rounded()))
      }
    }
    let hundred = PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus, wallBallReps: 100).steps[1]
    XCTAssertEqual(hundred.sets, Array(repeating: 10, count: 10)) // focus uses tens, not the race's 15s
    XCTAssertEqual(PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus, wallBallReps: 25).steps[1].sets, [10, 10, 5])
  }

  func testWallBallRepsSettingIsIgnoredOutsideTheOptionsAndOtherSessions() {
    XCTAssertEqual(PlanBuilder.build(division: .openMen, target: 4800, type: .wallBallFocus, wallBallReps: 60).steps[1].reps, 50)
    let full = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim, wallBallReps: 25)
    XCTAssertEqual(full.steps.last?.reps, 100)
    XCTAssertEqual(full, PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim))
  }

  func testWallBallSets() {
    XCTAssertEqual(Stations.wallBallSets(reps: 100), [15, 15, 15, 15, 15, 15, 10])
    XCTAssertEqual(Stations.wallBallSets(reps: 100).reduce(0, +), 100)
    XCTAssertEqual(Stations.wallBallSets(reps: 45), [10, 10, 10, 10, 5])
  }

  func testTargetIsClamped() {
    XCTAssertEqual(PlanBuilder.build(division: .openMen, target: 100, type: .fullSim).raceTargetSeconds, 1800)
    XCTAssertEqual(PlanBuilder.build(division: .openMen, target: 99_999, type: .fullSim).raceTargetSeconds, 10_800)
  }

  func testPlanRoundTripsThroughJSON() throws {
    let p = PlanBuilder.build(division: .openWomen, target: 5400, type: .fullSim)
    let back = try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(p))
    XCTAssertEqual(back, p)
  }

  func testFormats() {
    XCTAssertEqual(Fmt.clock(305), "5:05")
    XCTAssertEqual(Fmt.clock(4722), "1:18:42")
    XCTAssertEqual(Fmt.delta(32), "+0:32")
    XCTAssertEqual(Fmt.delta(-20), "\u{2212}0:20")
    XCTAssertEqual(Fmt.delta(0), "0:00")
    XCTAssertEqual(Fmt.spoken(75), "1 minute 15")
    XCTAssertEqual(Fmt.spoken(120), "2 minutes")
    XCTAssertEqual(Fmt.spoken(30), "thirty seconds")
    XCTAssertEqual(Fmt.spoken(33), "33 seconds")
  }
}
