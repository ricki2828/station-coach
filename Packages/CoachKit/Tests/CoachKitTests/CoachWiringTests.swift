import XCTest
@testable import CoachKit

final class CoachWiringTests: XCTestCase {
  private var root: URL!
  private let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-wiring-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  // MARK: WallBallTally

  func testTallyStartsAtZeroAndFreshResetsEverything() {
    let t = WallBallTally()
    t.begin(step: 15, fresh: true, earlier: [9, 9, 9])
    XCTAssertEqual(t.snapshot().count, 0, "fresh ignores earlier times")
    XCTAssertEqual(t.snapshot().times, [])
  }

  func testTallyCarriesEarlierRepsAfterARelaunch() {
    let t = WallBallTally()
    t.begin(step: 15, fresh: false, earlier: [10.0, 12.0, 14.0]) // a new process: nothing in the detector
    XCTAssertEqual(t.snapshot().count, 3)
    XCTAssertEqual(t.snapshot().times, [10.0, 12.0, 14.0])
    t.begin(step: 15, fresh: false, earlier: [1.0]) // the same step again: it keeps what it holds
    XCTAssertEqual(t.snapshot().count, 3)
  }

  func testTallyReloadsWhenAnotherStepOwnsTheDetector() {
    let t = WallBallTally()
    t.begin(step: 3, fresh: true, earlier: [])
    t.pause()
    t.begin(step: 7, fresh: true, earlier: [])
    t.pause()
    t.begin(step: 3, fresh: false, earlier: [20.0, 22.0]) // undo back across steps: step 3's banked times come back
    XCTAssertEqual(t.snapshot().times, [20.0, 22.0])
  }

  func testTallyIgnoresSamplesWhilePausedAndMillisecondsRound() {
    let t = WallBallTally()
    t.begin(step: 1, fresh: true, earlier: [])
    t.pause()
    for i in 0..<400 { t.feed(Double(i) * 0.01, i % 50 < 5 ? 2.0 : 0.05) }
    XCTAssertEqual(t.snapshot().count, 0)
    XCTAssertEqual(WallBallTally.milliseconds([1.2345, 2.0]), [1235, 2000])
  }

  // MARK: CoachCheckpointer

  private func folder(_ id: String) throws -> URL {
    let w = try SessionWriter(root: root, manifest: SessionManifest(sessionId: id, startedAtEpochMs: 1_000, device: "t", osVersion: "1", appVersion: "0", workoutActivityType: "crossTraining", motionApi: "x", requestedHz: 1, storeHz: 1, cueIntervalSec: 0))
    return w.folder
  }

  private func runningState(atStep k: Int) -> CoachSessionState {
    var s = CoachSessionState(plan: plan)
    s.machine.start(at: 1_000_000)
    for i in 0..<k { s.machine.advance(at: 1_000_000 + Int64(i + 1) * 60_000) }
    return s
  }

  func testCheckpointerBanksTheLiveRepsOfTheStepInProgress() throws {
    let f = try folder("cp1")
    let wall = plan.steps.count - 1
    var s = runningState(atStep: wall)
    _ = s.enterWallBalls(plan.steps[wall])
    s.repCorrection = 2
    let cp = CoachCheckpointer()
    XCTAssertNil(cp.save(s, liveRepTimesMs: [10, 20, 30], liveCount: 3, folder: f, nowMs: 5))
    guard case let .valid(loaded, _) = CoachCheckpoint.load(from: f) else { return XCTFail("should load") }
    XCTAssertEqual(loaded.state.repsByStep[wall], [10, 20, 30])
    XCTAssertEqual(loaded.state.correctionByStep[wall], 2)
    XCTAssertEqual(loaded.seq, 0)
    XCTAssertEqual(s.repsByStep[wall], nil, "the caller's state is not changed")
  }

  func testCheckpointerNumbersWritesAndResumesTheCount() throws {
    let f = try folder("cp2")
    let cp = CoachCheckpointer()
    cp.save(runningState(atStep: 1), liveRepTimesMs: [], liveCount: 0, folder: f, nowMs: 1)
    cp.save(runningState(atStep: 2), liveRepTimesMs: [], liveCount: 0, folder: f, nowMs: 2)
    guard case let .valid(a, _) = CoachCheckpoint.load(from: f) else { return XCTFail() }
    XCTAssertEqual(a.seq, 1)
    // After a resume the numbering carries on from the loaded one.
    let resumed = CoachCheckpointer(startingSeq: a.seq + 1)
    resumed.save(a.state, liveRepTimesMs: [], liveCount: 0, folder: f, nowMs: 3)
    guard case let .valid(b, _) = CoachCheckpoint.load(from: f) else { return XCTFail() }
    XCTAssertEqual(b.seq, 2)
  }

  func testCheckpointerWritesNothingForAFinishedSession() throws {
    let f = try folder("cp-done")
    var s = runningState(atStep: plan.steps.count - 1)
    s.machine.advance(at: 1_000_000 + Int64(plan.steps.count) * 60_000)
    XCTAssertNil(s.machine.current)
    let cp = CoachCheckpointer()
    cp.save(s, liveRepTimesMs: [], liveCount: 0, folder: f, nowMs: 1)
    XCTAssertEqual(CoachCheckpoint.load(from: f), .none)
    XCTAssertEqual(cp.seq, 0)
  }

  func testCheckpointerWritesOncePerRepCountChange() throws {
    let f = try folder("cp3")
    let cp = CoachCheckpointer()
    XCTAssertTrue(cp.repCountChanged(0), "never written: write")
    cp.save(runningState(atStep: 0), liveRepTimesMs: [], liveCount: 0, folder: f, nowMs: 1)
    XCTAssertFalse(cp.repCountChanged(0))
    XCTAssertTrue(cp.repCountChanged(1))
    cp.save(runningState(atStep: 0), liveRepTimesMs: [1], liveCount: 1, folder: f, nowMs: 2)
    XCTAssertFalse(cp.repCountChanged(1))
  }

  func testCheckpointerReportsAFailedWriteOnce() throws {
    let missing = root.appendingPathComponent("nope").appendingPathComponent("sid")
    let cp = CoachCheckpointer()
    XCTAssertNotNil(cp.save(runningState(atStep: 0), liveRepTimesMs: [], liveCount: 0, folder: missing, nowMs: 1))
    XCTAssertNil(cp.save(runningState(atStep: 0), liveRepTimesMs: [], liveCount: 0, folder: missing, nowMs: 2), "reported once")
  }

  // MARK: RecoveryTrigger

  func testRecoveryRequestedBeforeInstallRunsOnInstallOnce() {
    let trigger = RecoveryTrigger()
    var runs = 0
    trigger.request()
    XCTAssertEqual(runs, 0)
    trigger.install { runs += 1 }
    XCTAssertEqual(runs, 1)
    trigger.install { runs += 10 } // installing again does not replay it
    XCTAssertEqual(runs, 1)
  }

  func testRecoveryRequestedAfterInstallRunsAtOnce() {
    let trigger = RecoveryTrigger()
    var runs = 0
    trigger.install { runs += 1 }
    XCTAssertEqual(runs, 0, "nothing requested yet")
    trigger.request()
    trigger.request()
    XCTAssertEqual(runs, 2)
  }

  // MARK: AlarmGate

  func testASecondFaultWhileOneIsUpShowsAfterOKAndNothingIsDropped() {
    var g = AlarmGate()
    XCTAssertEqual(g.raise("No motion samples for 30 s", at: 0), .alarm)
    XCTAssertEqual(g.current, "No motion samples for 30 s")
    XCTAssertEqual(g.raise("No motion samples for 30 s", at: 10), .ignore, "the same fault needs no second copy")
    XCTAssertEqual(g.raise("Workout session ended", at: 10), .ignore, "waits its turn")
    XCTAssertEqual(g.raise("Workout session ended", at: 11), .ignore)
    XCTAssertEqual(g.raise("Motion stream failed", at: 12), .ignore)
    XCTAssertEqual(g.pending, ["Workout session ended", "Motion stream failed"])
    XCTAssertEqual(g.dismiss(), "Workout session ended", "OK on the stall shows the workout-ended alarm")
    XCTAssertEqual(g.current, "Workout session ended")
    XCTAssertEqual(g.dismiss(), "Motion stream failed")
    XCTAssertNil(g.dismiss())
    XCTAssertNil(g.current)
    XCTAssertEqual(g.pending, [])
    // All three were acknowledged: none comes back as an alarm.
    XCTAssertEqual(g.raise("Workout session ended", at: 20), .toast)
  }

  func testAPendingFaultThatClearsBeforeOKIsNotShown() {
    var g = AlarmGate()
    _ = g.raise("No motion samples for 30 s", at: 0)
    _ = g.raise("Motion never started", at: 1)
    g.clear("Motion never started")
    XCTAssertNil(g.dismiss())
  }

  func testAfterOKTheSameFaultNeverAlarmsAgainOnlyTheOccasionalToast() {
    var g = AlarmGate()
    let m = "No motion samples for 30 s"
    XCTAssertEqual(g.raise(m, at: 0), .alarm)
    g.dismiss()
    XCTAssertNil(g.current)
    XCTAssertEqual(g.raise(m, at: 10), .toast)
    for t in stride(from: 20.0, to: 120.0, by: 10.0) { XCTAssertEqual(g.raise(m, at: 10 + t), .ignore, "t=\(t)") }
    XCTAssertEqual(g.raise(m, at: 10 + AlarmGate.toastEvery), .toast)
  }

  func testAFaultThatClearsAndReturnsAlarmsAgain() {
    var g = AlarmGate()
    let m = "No motion samples for 30 s"
    _ = g.raise(m, at: 0)
    g.dismiss()
    XCTAssertEqual(g.raise(m, at: 10), .toast)
    g.clear(m)
    XCTAssertEqual(g.raise(m, at: 20), .alarm)
  }

  func testADifferentFaultAfterOKAlarms() {
    var g = AlarmGate()
    _ = g.raise("No motion samples for 30 s", at: 0)
    g.dismiss()
    XCTAssertEqual(g.raise("Workout session failed", at: 5), .alarm)
  }

  func testResetForgetsAcknowledgedFaults() {
    var g = AlarmGate()
    _ = g.raise("x", at: 0)
    g.dismiss()
    g.reset()
    XCTAssertEqual(g.raise("x", at: 1), .alarm)
  }
}
