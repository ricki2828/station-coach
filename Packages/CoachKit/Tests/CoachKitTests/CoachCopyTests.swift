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

  func testJogInIsDueInTheRunsLastTransitionSeconds() {
    let run = plan.steps[0], ski = plan.steps[1], tr = plan.transitionSeconds
    XCTAssertFalse(CoachCopy.jogInDue(run: run, next: ski, elapsedSeconds: run.targetSeconds - tr - 1, transitionSeconds: tr))
    XCTAssertTrue(CoachCopy.jogInDue(run: run, next: ski, elapsedSeconds: run.targetSeconds - tr, transitionSeconds: tr))
    XCTAssertTrue(CoachCopy.jogInDue(run: run, next: ski, elapsedSeconds: run.targetSeconds + 90, transitionSeconds: tr)) // slow run: still said
  }

  func testNoJogInWithoutAStationToJogTo() {
    let run = plan.steps[0], tr = plan.transitionSeconds
    XCTAssertFalse(CoachCopy.jogInDue(run: run, next: nil, elapsedSeconds: 9999, transitionSeconds: tr))
    XCTAssertFalse(CoachCopy.jogInDue(run: run, next: plan.steps[2], elapsedSeconds: 9999, transitionSeconds: tr)) // a run follows a run: never
    let none = PlanStep(activity: .skierg, index: 1, runNumber: nil, targetSeconds: 0, reps: nil, sets: [])
    XCTAssertFalse(CoachCopy.jogInDue(run: run, next: none, elapsedSeconds: 9999, transitionSeconds: tr))
    XCTAssertFalse(CoachCopy.jogInDue(run: plan.steps[1], next: plan.steps[2], elapsedSeconds: 9999, transitionSeconds: tr)) // not from a station
  }

  func testStationIntroNoLongerCarriesJogIn() {
    XCTAssertEqual(CoachCopy.stationIntro(plan.steps[1]), "SkiErg. 1,000 metres. Hinge from the hips.")
  }

  func testJogInIsItsOwnLowestPriorityCueSoTheGapRulesHold() {
    var s = CueScheduler()
    s.offer(CoachCue(kind: .planAndRun, text: "run", createdAt: 0))
    XCTAssertEqual(s.next(at: 0, speaking: false)?.text, "run")
    s.offer(CoachCue(kind: .jogIn, text: CoachCopy.jogIn, createdAt: 5))
    XCTAssertNil(s.next(at: 10, speaking: false)) // inside the 20 s gap: waits
    XCTAssertEqual(s.next(at: 20, speaking: false)?.text, "Jog in.")
    XCTAssertNil(s.next(at: 40, speaking: false)) // said once
    s.offer(CoachCue(kind: .jogIn, text: "Jog in.", createdAt: 100))
    s.offer(CoachCue(kind: .midStation, text: "mid", createdAt: 100))
    XCTAssertEqual(s.next(at: 100, speaking: false)?.text, "mid") // anything else outranks it
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

  func testNoRepNotedIsShortAndPlain() {
    XCTAssertEqual(CoachCopy.noRepNoted, "No rep noted.")
  }

  private func words(_ line: String) -> Int { line.split(separator: " ").count }

  func testSessionStartLines() {
    XCTAssertEqual(CoachCopy.sessionStart(plan: plan, isFirst: true), "Target 80 minutes. Start easy, run 1 sets your baseline.")
    XCTAssertEqual(CoachCopy.sessionStart(plan: plan, isFirst: false), "Target 80 minutes. Hold run 1 back.")
    XCTAssertFalse(CoachCopy.sessionStart(plan: plan, isFirst: true).contains("1:20"), "spoken with Fmt.spoken, not a clock reading")
  }

  func testFinishPersonalityEveryBranch() {
    func p(_ t: Int, first: Bool, early: Bool, saved: Bool = true) -> String {
      CoachCopy.finishPersonality(totalSeconds: t, plannedSeconds: 4800, isFirst: first, early: early, saved: saved)
    }
    XCTAssertEqual(p(2000, first: true, early: true), "Ended early. Everything up to here is saved.")
    XCTAssertEqual(p(4900, first: true, early: false), "First session logged. This time is your baseline.")
    XCTAssertEqual(p(4722, first: false, early: false), "Hold that next time.")
    XCTAssertEqual(p(4900, first: false, early: false), "Start with your slowest station.")
    XCTAssertEqual(p(4800, first: false, early: false), "Exactly the plan.")
  }

  func testPersonalityNeverClaimsASaveThatFailed() {
    for (first, early) in [(true, true), (true, false), (false, true), (false, false)] {
      let line = CoachCopy.finishPersonality(totalSeconds: 4900, plannedSeconds: 4800, isFirst: first, early: early, saved: false)
      XCTAssertFalse(line.lowercased().contains("saved"), line)
      XCTAssertFalse(line.lowercased().contains("logged"), line)
    }
  }

  func testPersonalityDoesNotRepeatWhatFinishSpoke() {
    for total in [4722, 4900, 4800] {
      let spoken = CoachCopy.finish(totalSeconds: total, plannedSeconds: 4800, best: nil, worst: nil, early: false)
      let line = CoachCopy.finishPersonality(totalSeconds: total, plannedSeconds: 4800, isFirst: false, early: false, saved: true)
      XCTAssertFalse(line.contains(":"), "no clock reading in \(line)")
      XCTAssertFalse(line.lowercased().contains("target"), "\(line) repeats the gap already in: \(spoken)")
    }
  }

  func testNewLinesStayShortAndClean() {
    var lines = [CoachCopy.sessionStart(plan: plan, isFirst: true), CoachCopy.sessionStart(plan: plan, isFirst: false)]
    for (t, e, f) in [(2000, true, true), (4900, false, true), (4722, false, false), (5800, false, false), (4800, false, false)] {
      lines.append(CoachCopy.finishPersonality(totalSeconds: t, plannedSeconds: 4800, isFirst: f, early: e, saved: true))
    }
    for line in lines {
      XCTAssertLessThanOrEqual(words(line), 12, line)
      let l = line.lowercased()
      for banned in ["ai ", "hyrox", "skierg", "great job", "keep going"] { XCTAssertFalse(l.contains(banned), line) }
    }
  }

  func testSessionLabel() {
    XCTAssertNil(CoachCopy.sessionLabel(early: false, recovered: false))
    XCTAssertEqual(CoachCopy.sessionLabel(early: true, recovered: false), "Ended early")
    XCTAssertEqual(CoachCopy.sessionLabel(early: true, recovered: true), "Recovered")
    XCTAssertEqual(CoachCopy.sessionLabel(early: false, recovered: true), "Recovered")
  }
}
