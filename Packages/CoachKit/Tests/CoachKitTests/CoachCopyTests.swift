import XCTest
@testable import CoachKit

final class CoachCopyTests: XCTestCase {
  private let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)

  func testPlanCheckLines() {
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -30), "Thirty seconds up on plan.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: 20), "Twenty seconds down, stay calm.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: 4), "On plan.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -9), "On plan.")
    XCTAssertEqual(CoachCopy.planCheck(deltaSeconds: -75), "1 minute 15 up on plan.")
  }

  func testWallBallIntro() {
    let wb = plan.steps.last!
    XCTAssertEqual(CoachCopy.stationIntro(wb), "Wall balls. 100 reps. Sets of 15, five breaths between.")
  }

  func testJogInOpensTheIntroAfterARunOnly() {
    let run = plan.steps[0], ski = plan.steps[1], sledPush = plan.steps[3]
    XCTAssertEqual(CoachCopy.stationIntro(ski, after: run), "Jog in. SkiErg. 1,000 metres. Hinge from the hips.")
    XCTAssertEqual(CoachCopy.stationIntro(ski), "SkiErg. 1,000 metres. Hinge from the hips.") // no previous step: unchanged
    XCTAssertEqual(CoachCopy.stationIntro(sledPush, after: ski), CoachCopy.stationIntro(sledPush)) // not after a run
    for station in plan.steps where !station.isRun {
      let said = CoachCopy.stationIntro(station, after: plan.steps[station.index - 1])
      XCTAssertEqual(said.components(separatedBy: "Jog in").count - 1, 1, "once: \(said)")
    }
  }

  func testNoJogInWithoutAStationTarget() {
    let ski = plan.steps[1]
    let none = PlanStep(activity: ski.activity, index: ski.index, runNumber: nil, targetSeconds: 0, reps: nil, sets: [])
    XCTAssertEqual(CoachCopy.stationIntro(none, after: plan.steps[0]), CoachCopy.stationIntro(none))
  }

  func testJogInIsPartOfTheOneIntroCueSoTheGapRulesHold() {
    var s = CueScheduler()
    s.offer(CoachCue(kind: .planAndRun, text: "run", createdAt: 0))
    XCTAssertEqual(s.next(at: 0, speaking: false)?.text, "run")
    s.offer(CoachCue(kind: .stationIntro, text: CoachCopy.stationIntro(plan.steps[1], after: plan.steps[0]), createdAt: 5))
    XCTAssertNil(s.next(at: 10, speaking: false)) // inside the 20 s gap: waits
    XCTAssertTrue(s.next(at: 20, speaking: false)?.text.hasPrefix("Jog in. SkiErg") ?? false)
    XCTAssertNil(s.next(at: 40, speaking: false)) // said once
  }

  func testEveryStationHasAnIntroWithTheName() {
    for s in plan.steps where !s.isRun {
      XCTAssertTrue(CoachCopy.stationIntro(s).hasPrefix(Stations.name(s.activity)), s.name)
    }
  }

  func testRunStartAfterSledCarriesLegsLine() {
    let run2 = plan.steps[2], push = plan.steps[3]
    XCTAssertEqual(
      CoachCopy.runStart(run: plan.steps[4], after: push, deltaSeconds: -30, transitionSeconds: plan.transitionSeconds),
      "Thirty seconds up on plan. Legs feel heavy for 200 metres. Short quick steps. Target 4:48 for this kilometre.")
    XCTAssertEqual(CoachCopy.runStart(run: run2, after: plan.steps[1], deltaSeconds: 20, transitionSeconds: plan.transitionSeconds),
                   "Twenty seconds down, stay calm. Target 4:48 for this kilometre.")
    XCTAssertEqual(CoachCopy.runStart(run: plan.steps[0], after: nil, deltaSeconds: 0, transitionSeconds: plan.transitionSeconds), "Target 4:48 for this kilometre.")
  }

  func testMidStationCues() {
    XCTAssertEqual(CoachCopy.midStation(plan.steps[1]), "Hold 2:12 per 500. Build the last 200.")
    XCTAssertNil(CoachCopy.midStation(plan.steps.last!))
    XCTAssertNil(CoachCopy.midStation(plan.steps[0]))
  }

  func testWallBallSetDone() {
    XCTAssertEqual(CoachCopy.wallBallSetDone(nextSet: 15), "Set done. Breathe. Next fifteen.")
    XCTAssertEqual(CoachCopy.wallBallSetDone(nextSet: 10), "Set done. Breathe. Next ten.")
  }

  func testFinishLine() {
    XCTAssertEqual(
      CoachCopy.finish(totalSeconds: 4722, plannedSeconds: 4800, best: ("Row", -25), worst: ("Sled pull", 41), early: false),
      "1:18:42. 1:18 under target. Best: Row, 0:25 under. Worst: Sled pull, 0:41 over.")
    XCTAssertEqual(
      CoachCopy.finish(totalSeconds: 2000, plannedSeconds: 2400, best: nil, worst: nil, early: true), "33:20.")
  }

  func testNoFillerPhrases() {
    let all = plan.steps.compactMap { CoachCopy.midStation($0) } + plan.steps.map { CoachCopy.stationIntro($0) }
    for line in all {
      XCTAssertFalse(line.lowercased().contains("great job"))
      XCTAssertFalse(line.lowercased().contains("keep going"))
    }
  }
}
