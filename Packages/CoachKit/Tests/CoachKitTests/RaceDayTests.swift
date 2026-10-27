import XCTest
@testable import CoachKit

final class RaceDayTests: XCTestCase {
  private let t0: Int64 = 1_000_000
  private let step: Int64 = 60_000

  private func plan(_ type: SessionType = .raceDay, target: Int = 4800, division: Division = .openMen) -> SessionPlan {
    PlanBuilder.build(division: division, target: target, type: type)
  }

  /// A machine started at t0; `go` advances it by whole minutes so the debounce never gets in the way.
  private func started(_ type: SessionType = .raceDay) -> SessionMachine {
    var m = SessionMachine(plan: plan(type))
    m.start(at: t0)
    return m
  }

  private func at(_ n: Int) -> Int64 { t0 + Int64(n) * step }

  // MARK: Race plan

  func testRaceSplitsSumToTheTargetWithinASecondForEveryDivision() {
    for division in Division.allCases {
      for target in [1800, 3600, 4800, 5400, 7200, 10_800] {
        let p = plan(.raceDay, target: target, division: division)
        let sum = RacePlan.segments(p).map(\.targetSeconds).reduce(0, +)
        XCTAssertLessThanOrEqual(abs(sum - target), 1, "\(division) \(target): \(sum)")
        XCTAssertEqual(p.plannedSeconds, sum)
      }
    }
  }

  func testRaceDayHasTheFullSimShape() {
    let race = plan(.raceDay), full = plan(.fullSim)
    XCTAssertEqual(race.steps.map(\.activity), full.steps.map(\.activity))
    XCTAssertEqual(race.steps.map(\.targetSeconds), full.steps.map(\.targetSeconds), "keeps the division targets")
    XCTAssertEqual(race.type, .raceDay)
    XCTAssertEqual(RacePlan.segments(race).count, 16)
    XCTAssertEqual(RacePlan.line(RacePlan.segments(race)[0]), "Run 1 \u{00B7} \(Fmt.clock(race.steps[0].targetSeconds))")
  }

  func testRaceDayRoundTripsAndNeverCarriesAGhost() throws {
    let p = plan()
    XCTAssertEqual(try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(p)), p)
    XCTAssertEqual(SessionType(rawValue: "race_day"), .raceDay)
    let offer = GhostOffer(available: true, title: "Last race day", sub: "x", splits: p.steps.map(\.targetSeconds))
    XCTAssertNil(Ghost.plan(p, racing: offer, race: true).ghostSplits, "race day is always against the plan (D6)")
  }

  // MARK: Quiet coach

  func testRaceDaySilencesTheMidStationAndJogInCuesOnly() {
    for kind in [CoachCueKind.midStation, .jogIn] { XCTAssertTrue(SessionType.raceDay.silences(kind)) }
    for kind in [CoachCueKind.stationIntro, .planAndRun, .wallBallSet, .noRep, .finish] {
      XCTAssertFalse(SessionType.raceDay.silences(kind), "\(kind) is a split call")
    }
    for type in [SessionType.fullSim, .halfSim, .wallBallFocus] {
      for kind in [CoachCueKind.midStation, .jogIn, .stationIntro] { XCTAssertFalse(type.silences(kind)) }
    }
    XCTAssertFalse(SessionType.raceDay.allowsDoItLater)
    XCTAssertTrue(SessionType.fullSim.allowsDoItLater)
  }

  func testRaceVoice() {
    let p = plan()
    XCTAssertEqual(CoachCopy.raceStart(plan: p, run: p.steps[0]),
                   "Race day. Target 80 minutes. Run 1, \(Fmt.clock(p.steps[0].targetSeconds - 2 * p.transitionSeconds)) for the kilometre.")
    XCTAssertEqual(CoachCopy.raceStation(p.steps[3]), "Sled push. Target \(Fmt.clock(p.steps[3].targetSeconds)).")
    let line = CoachCopy.raceRunStart(stationSeconds: 250, deltaSeconds: 8, after: p.steps[3], run: p.steps[4], transitionSeconds: p.transitionSeconds)
    XCTAssertEqual(line, "4:10. 8 seconds down. Short quick steps. Run 3, target \(Fmt.clock(p.steps[4].targetSeconds - 2 * p.transitionSeconds)).")
    let ahead = CoachCopy.raceRunStart(stationSeconds: 250, deltaSeconds: -20, after: p.steps[1], run: p.steps[2], transitionSeconds: p.transitionSeconds)
    XCTAssertTrue(ahead.hasPrefix("4:10. 20 seconds up. Run 2, target"), ahead) // SkiErg: no legs line
    XCTAssertTrue(CoachCopy.raceRunStart(stationSeconds: 250, deltaSeconds: 1, after: p.steps[1], run: p.steps[2], transitionSeconds: 10).contains("On plan."))
    XCTAssertEqual(CoachCopy.raceWallBallSet(nextSet: 15), "Set done. Next fifteen.")
    XCTAssertEqual(CoachCopy.raceWallBallSet(nextSet: nil), "Set done. Last one done.")
    for text in [CoachCopy.raceStart(plan: p, run: p.steps[0]), CoachCopy.raceStation(p.steps[3]), line, CoachCopy.raceWallBallSet(nextSet: 10)] {
      let l = text.lowercased()
      for banned in ["hyrox", "roxzone", "transition", "breathe"] { XCTAssertFalse(l.contains(banned), text) }
    }
  }

  func testChangeoverIsTheOnlyWordForTheWalkInEverywhere() {
    XCTAssertEqual(Stations.name(.transition), "Changeover")
    XCTAssertEqual(Activity.transition.buttonTitle, "Changeover")
    XCTAssertEqual(RacePlan.footnote(plan()), "Runs include changeovers (about \(Fmt.clock(plan().transitionSeconds)) each).")
  }

  // MARK: Skipping

  func testSkipLogsAFlaggedSplitAndMovesOn() {
    var m = started()
    for n in 1...2 { m.advance(at: at(n * 2)) } // run 1 -> SkiErg -> run 2
    m.advance(at: at(6)) // run 2 -> sled push
    XCTAssertEqual(m.current?.activity, .sledPush)
    XCTAssertEqual(m.skip(later: false, at: at(8)), .started(4))
    XCTAssertTrue(m.splits[3].isSkipped)
    XCTAssertNotNil(m.splits[3].endMs)
    XCTAssertEqual(m.current?.index, 4)
    XCTAssertEqual(m.skippedStations, [3])
    XCTAssertFalse(m.doneSteps.contains(3))
  }

  func testARunCannotBeSkipped() {
    var m = started()
    XCTAssertEqual(m.skip(later: false, at: at(5)), .ignored)
    XCTAssertEqual(m.skip(later: true, at: at(5)), .ignored)
    XCTAssertEqual(m.currentIndex, 0)
  }

  func testSkippedStepIsOutOfTheDelta() {
    var m = started()
    m.advance(at: at(5))                       // run 1 took 5 min
    let before = m.deltaSeconds(at: at(5))
    m.skip(later: false, at: at(30))           // 25 minutes spent on SkiErg, then skipped
    XCTAssertEqual(m.deltaSeconds(at: at(30)), before, "the skipped station is out of both sides")
  }

  func testSkippingTheLastStationFinishesWithASkippedSplit() {
    var m = started()
    var n = 1
    while m.current?.index != 15 { m.advance(at: at(n * 2)); n += 1 }
    XCTAssertEqual(m.skip(later: false, at: at(n * 2)), .finished)
    XCTAssertEqual(m.phase, .finished(early: false))
    XCTAssertEqual(m.splits.count, 16)
    XCTAssertTrue(m.splits[15].isSkipped)
    XCTAssertEqual(m.skippedStations, [15])
  }

  func testDoItLaterMovesTheStationAfterTheNextOne() {
    var m = started(.fullSim)
    m.advance(at: at(2))                          // run 1 -> SkiErg (1)
    m.advance(at: at(4))                          // -> run 2 (2)
    m.advance(at: at(6))                          // -> sled push (3)
    XCTAssertEqual(m.skip(later: true, at: at(8)), .started(4)) // run 3 now
    XCTAssertEqual(Array(m.order.prefix(8)), [0, 1, 2, 4, 5, 3, 6, 7], "sled push moves behind the next station, sled pull")
    XCTAssertTrue(m.splits[3].isSkipped)
    // Walk on: run 3, sled pull, then the moved sled push, then run 4.
    XCTAssertEqual(m.advance(at: at(10)), .started(5))
    XCTAssertEqual(m.advance(at: at(12)), .started(3), "the moved station comes back")
    XCTAssertEqual(m.advance(at: at(14)), .started(6))
    XCTAssertEqual(m.skippedStations, [], "it was done in the end: not skipped")
    XCTAssertTrue(m.doneSteps.contains(3))
  }

  func testDoItLaterOnTheLastStationOffersItAtTheEnd() {
    var m = started(.fullSim)
    var n = 1
    while m.current?.index != 15 { m.advance(at: at(n * 2)); n += 1 }
    XCTAssertEqual(m.skip(later: true, at: at(n * 2)), .leftover)
    XCTAssertEqual(m.phase, .awaitingLeftover)
    XCTAssertEqual(m.leftoverStep?.index, 15)
    XCTAssertNil(m.current)
    XCTAssertTrue(m.isConsistent)
    // Do it now: it becomes the last step again.
    XCTAssertEqual(m.doLeftover(at: at(n * 2 + 2)), .started(15))
    XCTAssertEqual(m.phase, .running)
    XCTAssertEqual(m.advance(at: at(n * 2 + 6)), .finished)
    XCTAssertEqual(m.skippedStations, [])
  }

  func testFinishWithoutTheLeftoverKeepsItSkipped() {
    var m = started(.fullSim)
    var n = 1
    while m.current?.index != 15 { m.advance(at: at(n * 2)); n += 1 }
    m.skip(later: true, at: at(n * 2))
    XCTAssertEqual(m.finishWithoutLeftover(at: at(n * 2 + 2)), .finished)
    XCTAssertEqual(m.phase, .finished(early: false))
    XCTAssertEqual(m.skippedStations, [15])
    XCTAssertTrue(m.isConsistent)
  }

  func testEndingEarlyFromTheLeftoverPrompt() {
    var m = started(.fullSim)
    var n = 1
    while m.current?.index != 15 { m.advance(at: at(n * 2)); n += 1 }
    m.skip(later: true, at: at(n * 2))
    m.end(at: at(n * 2 + 3))
    XCTAssertEqual(m.phase, .finished(early: true))
    XCTAssertFalse(m.undo(at: at(n * 2 + 4)), "an early end is final")
  }

  func testUndoReversesASkipAMoveAndTheLeftoverExactly() {
    var m = started(.fullSim)
    m.advance(at: at(2)); m.advance(at: at(4)); m.advance(at: at(6)) // on sled push (3)
    let before = m
    m.skip(later: true, at: at(8))
    XCTAssertTrue(m.undo(at: at(9)))
    XCTAssertEqual(m.order, before.order)
    XCTAssertEqual(m.splits, before.splits)
    XCTAssertEqual(m.currentIndex, 3)
    XCTAssertEqual(m.deltaSeconds(at: at(6)), before.deltaSeconds(at: at(6)))
    m.skip(later: false, at: at(10))
    XCTAssertTrue(m.undo(at: at(11)))
    XCTAssertEqual(m.splits, before.splits)
    XCTAssertTrue(m.skippedStations.isEmpty)
    // The leftover round trip.
    var n = 4
    while m.current?.index != 15 { m.advance(at: at(n * 2 + 20)); n += 1 }
    let atLast = m
    m.skip(later: true, at: at(n * 2 + 20))
    XCTAssertTrue(m.undo(at: at(n * 2 + 21)))
    XCTAssertEqual(m.splits, atLast.splits)
    XCTAssertEqual(m.order, atLast.order)
    XCTAssertEqual(m.deferred, atLast.deferred)
    XCTAssertEqual(m.phase, atLast.phase)
    m.skip(later: true, at: at(n * 2 + 22))
    m.doLeftover(at: at(n * 2 + 23))
    XCTAssertTrue(m.undo(at: at(n * 2 + 24)))
    XCTAssertEqual(m.phase, .awaitingLeftover)
  }

  func testASkippedStepNeverMakesACompleteSplitSet() {
    var m = started(.fullSim)
    var n = 1
    while m.current?.index != 15 { m.advance(at: at(n * 2)); n += 1 }
    m.skip(later: false, at: at(n * 2))
    let state = CoachSessionState(machine: m)
    let r = state.makeResult(early: false, endedAtEpochMs: at(n * 2))!
    XCTAssertNil(Ghost.stepSeconds(r), "every split is there, but one is flagged skipped")
    XCTAssertFalse(Ghost.isEligible(r, for: plan(.fullSim)))
  }

  // MARK: Result, history, load

  private func resultWithASkippedRow() -> CoachResult {
    var m = started(.fullSim)
    var n = 1
    // Through step 8 normally, skip the Row (index 9), then finish the rest.
    while m.current?.index != 9 { m.advance(at: at(n * 2)); n += 1 }
    m.skip(later: false, at: at(n * 2)); n += 1
    while m.phase == .running { m.advance(at: at(n * 2)); n += 1 }
    return CoachSessionState(machine: m).makeResult(early: false, endedAtEpochMs: at(n * 2))!
  }

  func testSkippedStationIsNotDoneInTheResult() {
    let r = resultWithASkippedRow()
    XCTAssertFalse(r.early)
    XCTAssertEqual(r.skippedStationCount, 1)
    let row = r.rows[9]
    XCTAssertNil(row.actualSeconds, "never 0:00")
    XCTAssertTrue(row.skipped)
    XCTAssertEqual(r.completedStationCount, 7)
    XCTAssertEqual(r.rows.filter { $0.actualSeconds != nil }.count, 15)
    XCTAssertNotEqual(r.bestWorstStations.best?.0, "Row")
    XCTAssertNotEqual(r.bestWorstStations.worst?.0, "Row")
    XCTAssertEqual(CoachCopy.skippedCount(1), "1 station skipped.")
    XCTAssertEqual(CoachCopy.skippedCount(2), "2 stations skipped.")
    XCTAssertEqual(CoachCopy.finish(totalSeconds: 4360, plannedSeconds: 4800, best: nil, worst: nil, early: false, skipped: 1), "1:12:40. 1 station skipped.")
  }

  func testASessionWithASkipIsNotCompleteNoBestNoTargetLine() {
    let rec = SessionRecord(id: "s", result: resultWithASkippedRow())
    XCTAssertFalse(rec.isComplete)
    XCTAssertNil(rec.targetWords)
    let older = SessionRecord(id: "old", result: { var r = resultWithASkippedRow(); r.splits[9].skipped = nil; return r }())
    XCTAssertTrue(older.isComplete)
    XCTAssertNil(MomentPicker.pick(previous: [older], new: rec), "a skip never earns a moment")
  }

  func testTrainingLoadTreatsASkippedStationAsNotDone() throws {
    let skipped = resultWithASkippedRow()
    var clean = skipped
    clean.splits[9].skipped = nil
    let a = SessionLoad.of(skipped, hr: nil, maxHR: 185)
    let b = SessionLoad.of(clean, hr: nil, maxHR: 185)
    XCTAssertEqual(a.stationMetres, b.stationMetres - Int(SessionLoad.metres(.row)), "the Row's metres are not counted")
    XCTAssertEqual(a.simKm, b.simKm)
    XCTAssertTrue(a.load.isFinite)
    XCTAssertGreaterThan(a.load, 0)
    XCTAssertEqual(a.minutes, b.minutes, accuracy: 0.001, "the time spent still counts as time")
  }

  func testSkippedSplitsDecodeAndOldFilesStillDo() throws {
    let r = resultWithASkippedRow()
    let back = try JSONDecoder().decode(CoachResult.self, from: JSONEncoder().encode(r))
    XCTAssertEqual(back, r)
    XCTAssertEqual(back.skippedStationCount, 1)
    var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    var splits = try XCTUnwrap(obj["splits"] as? [[String: Any]])
    for i in splits.indices { splits[i].removeValue(forKey: "skipped") }
    obj["splits"] = splits
    let old = try JSONDecoder().decode(CoachResult.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertEqual(old.skippedStationCount, 0)
  }

  func testRepsCountedBeforeASkipAreNotPartOfTheResult() {
    let wall = plan(.fullSim).steps.count - 1
    var state = CoachSessionState(plan: plan(.fullSim))
    state.machine.start(at: t0)
    var n = 1
    while state.machine.current?.index != wall { state.machine.advance(at: at(n * 2)); n += 1 }
    let step = state.machine.current!
    _ = state.enterWallBalls(step)
    state.bank(step: step, repTimesMs: [1, 2, 3])
    state.noRepLog.add(NoRepEvent(tMs: 5, setIndex: 0, stepIndex: step.index))
    state.machine.skip(later: false, at: at(n * 2))
    let r = state.makeResult(early: false, endedAtEpochMs: at(n * 2))!
    XCTAssertEqual(r.repTimesMs, [])
    XCTAssertEqual(r.noReps, [])
    XCTAssertEqual(r.wallBallSets(), [])
  }

  // MARK: Checkpoint compatibility

  func testMachineStateSurvivesACheckpointRoundTripIncludingTheOrderAndUndo() throws {
    var m = started(.fullSim)
    m.advance(at: at(2)); m.advance(at: at(4)); m.advance(at: at(6))
    m.skip(later: true, at: at(8))
    let back = try JSONDecoder().decode(SessionMachine.self, from: JSONEncoder().encode(m))
    XCTAssertEqual(back, m)
    XCTAssertTrue(back.isConsistent)
    var resumed = back
    XCTAssertTrue(resumed.undo(at: at(9)), "undo history survives a relaunch")
    XCTAssertEqual(resumed.currentIndex, 3)
  }

  func testACheckpointFromBeforeSkippingStillDecodesAsPlanOrder() throws {
    var m = started(.fullSim)
    m.advance(at: at(2)); m.advance(at: at(4))
    var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
    for key in ["order", "pos", "deferred", "history"] { obj.removeValue(forKey: key) }
    let old = try JSONDecoder().decode(SessionMachine.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertEqual(old.order, Array(0..<16))
    XCTAssertEqual(old.pos, 2)
    XCTAssertTrue(old.isConsistent)
    XCTAssertEqual(old.next?.index, 3)
  }

  func testInconsistentOrdersAreRefused() throws {
    var m = started(.fullSim)
    m.advance(at: at(2))
    var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
    obj["order"] = [0, 0, 2]
    let dup = try JSONDecoder().decode(SessionMachine.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertFalse(dup.isConsistent, "a duplicated step")
    obj["order"] = Array(0..<16)
    obj["pos"] = 7
    let moved = try JSONDecoder().decode(SessionMachine.self, from: JSONSerialization.data(withJSONObject: obj))
    XCTAssertFalse(moved.isConsistent, "pos does not point at the open step")
  }
}
