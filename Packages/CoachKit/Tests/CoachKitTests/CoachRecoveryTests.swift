import XCTest
@testable import CoachKit

final class CoachRecoveryTests: XCTestCase {
  private var root: URL!
  private let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim)
  private let t0: Int64 = 1_000_000

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  // MARK: Helpers

  private var wallBallStep: PlanStep { plan.steps.first { $0.activity == .wallBalls }! }

  /// A session started at `t0` and advanced to step `k`, one minute per step.
  private func state(atStep k: Int) -> CoachSessionState {
    var s = CoachSessionState(plan: plan)
    s.machine.start(at: t0)
    for i in 0..<k { s.machine.advance(at: t0 + Int64(i + 1) * 60_000) }
    return s
  }

  private func manifest(_ id: String) -> SessionManifest {
    SessionManifest(sessionId: id, startedAtEpochMs: 1_000, device: "test", osVersion: "1", appVersion: "0.1", workoutActivityType: "crossTraining", motionApi: "CMBatchedSensorManager", requestedHz: 800, storeHz: 100, cueIntervalSec: 0)
  }

  private func unfinishedFolder(_ id: String) throws -> URL {
    let w = try SessionWriter(root: root, manifest: manifest(id))
    w.append(.labels, "5,set,run")
    w.flushAll()
    return w.folder
  }

  private func checkpoint(_ id: String, _ s: CoachSessionState, seq: Int = 1, savedAt: Int64 = 5_000) -> CoachCheckpoint {
    CoachCheckpoint(sessionId: id, savedAtEpochMs: savedAt, seq: seq, state: s)
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  private func names(_ folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }

  // MARK: Pure state

  func testRepsDoneCountsManualCorrectionAndNoReps() {
    var s = state(atStep: plan.steps.firstIndex { $0.activity == .wallBalls }!)
    let step = wallBallStep
    XCTAssertEqual(s.repsDone(step, counted: 10), 10)
    s.repCorrection = 3
    XCTAssertEqual(s.repsDone(step, counted: 10), 13)
    s.noRepLog.add(NoRepEvent(tMs: 1, setIndex: 0, stepIndex: step.index))
    s.noRepLog.add(NoRepEvent(tMs: 2, setIndex: 0, stepIndex: step.index))
    XCTAssertEqual(s.repsDone(step, counted: 10), 11)
    s.noRepLog.add(NoRepEvent(tMs: 3, setIndex: 0, stepIndex: step.index - 1)) // another step: not counted here
    XCTAssertEqual(s.repsDone(step, counted: 10), 11)
    XCTAssertEqual(s.repsDone(step, counted: 500), step.reps ?? 100) // capped at the step's reps
    s.repCorrection = -50
    XCTAssertEqual(s.repsDone(step, counted: 10), 0) // never negative
  }

  func testSetsAreAnnouncedOnceAndNotAgainAfterAnUndoBackIn() {
    var s = state(atStep: 0)
    let step = wallBallStep
    let first = step.sets[0], second = step.sets[1]
    XCTAssertTrue(s.newlyDoneSets(step, repsDone: first - 1).isEmpty)
    let a = s.newlyDoneSets(step, repsDone: first)
    XCTAssertEqual(a.map(\.index), [0])
    XCTAssertEqual(a.first?.next, second)
    XCTAssertTrue(s.newlyDoneSets(step, repsDone: first).isEmpty) // not twice
    // Two sets pass at once (a +/- jump): both come back, in order.
    let b = s.newlyDoneSets(step, repsDone: first + second + step.sets[2])
    XCTAssertEqual(b.map(\.index), [1, 2])
    // An undo back into the step re-derives what was passed, so nothing is said again.
    s.resetAnnouncedSets(for: step, repsDone: first + second)
    XCTAssertEqual(s.announcedSets, [0, 1])
    XCTAssertTrue(s.newlyDoneSets(step, repsDone: first + second).isEmpty)
    XCTAssertEqual(s.newlyDoneSets(step, repsDone: first + second + step.sets[2]).map(\.index), [2])
    // The last set has no next.
    s.resetAnnouncedSets(for: step, repsDone: 0)
    XCTAssertNil(s.newlyDoneSets(step, repsDone: step.reps ?? 100).last?.next)
  }

  func testEnteringWallBallsAgainBringsBackTheEarlierCorrection() {
    var s = state(atStep: 0)
    let step = wallBallStep
    XCTAssertTrue(s.enterWallBalls(step))
    s.repCorrection = 4
    s.bank(step: step, repTimesMs: [10, 20, 30])
    s.repCorrection = 0 // moved on to another step
    XCTAssertFalse(s.enterWallBalls(step))
    XCTAssertEqual(s.repCorrection, 4)
    XCTAssertEqual(s.repsByStep[step.index], [10, 20, 30])
  }

  func testWallBallsAreTheLastStepOfTheFullSim() {
    XCTAssertEqual(wallBallStep.index, plan.steps.count - 1) // the tests below finish the session from there
  }

  func testBankIgnoresStepsThatAreNotWallBalls() {
    var s = state(atStep: 0)
    s.bank(step: plan.steps[0], repTimesMs: [1])
    XCTAssertTrue(s.repsByStep.isEmpty)
  }

  func testUndoFinishReopensTheLastStepAndKeepsTheRestOfTheState() {
    let last = plan.steps.count - 1
    var s = state(atStep: last)
    let step = plan.steps[last]
    _ = s.enterWallBalls(step)
    s.bank(step: step, repTimesMs: [100, 200])
    XCTAssertEqual(s.machine.advance(at: t0 + Int64(last + 1) * 60_000), .finished)
    let done = s.makeResult(early: false, endedAtEpochMs: 0)
    XCTAssertEqual(done?.early, false)
    XCTAssertEqual(done?.splits.count, plan.steps.count)
    XCTAssertTrue(s.machine.undo(at: t0 + 700_000_000))
    XCTAssertEqual(s.machine.currentIndex, last)
    XCTAssertNil(s.machine.splits.last?.endMs)
    XCTAssertEqual(s.repsByStep[step.index], [100, 200])
    XCTAssertTrue(s.isConsistent)
  }

  func testMakeResultMatchesAnUninterruptedFinish() throws {
    var s = state(atStep: plan.steps.count - 1)
    let step = plan.steps[plan.steps.count - 1]
    _ = s.enterWallBalls(step)
    s.repCorrection = 2
    s.bank(step: step, repTimesMs: [300, 100, 200])
    s.noRepLog.add(NoRepEvent(tMs: 150, setIndex: 0, stepIndex: step.index))
    let endMs = t0 + 20 * 60_000
    s.machine.end(at: endMs)
    let r = try XCTUnwrap(s.makeResult(early: true, endedAtEpochMs: endMs))
    XCTAssertEqual(r.repTimesMs, [100, 200, 300])
    XCTAssertEqual(r.repCorrection, 2)
    XCTAssertEqual(r.noReps.count, 1)
    XCTAssertTrue(r.early)
    XCTAssertEqual(r.startedAtEpochMs, t0)
    XCTAssertEqual(r.endedAtEpochMs, endMs)
  }

  func testMakeResultOfASessionThatNeverStartedIsNil() {
    XCTAssertNil(CoachSessionState(plan: plan).makeResult(early: true, endedAtEpochMs: 1))
  }

  // MARK: Checkpoint round trip and resume

  func testStateRoundTripsThroughJSON() throws {
    var s = state(atStep: 6)
    _ = s.enterWallBalls(wallBallStep)
    s.repCorrection = -1
    s.bank(step: wallBallStep, repTimesMs: [1, 2, 3])
    s.noRepLog.add(NoRepEvent(tMs: 9, setIndex: 1, stepIndex: wallBallStep.index))
    s.announcedSets = [0, 1]
    s.midCueDone = [3]
    s.jogInDone = [2, 4]
    s.noRepAnnounced = true
    let back = try JSONDecoder().decode(CoachSessionState.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(back, s)
  }

  func testResumedSessionProducesTheSameSplitsAsOneThatNeverCrashed() throws {
    let id = "resume1"
    let folder = try unfinishedFolder(id)
    // Uninterrupted: steps 0...9, then the end.
    var straight = state(atStep: 9)
    straight.machine.end(at: t0 + 12 * 60_000)
    // Crashed after step 9 began: checkpoint, relaunch, carry on.
    let before = state(atStep: 9)
    try CoachCheckpoint.write(checkpoint(id, before), to: folder)
    guard case let .valid(cp, usedBackup) = CoachCheckpoint.load(from: folder) else { return XCTFail("checkpoint should load") }
    XCTAssertFalse(usedBackup)
    var resumed = cp.state
    XCTAssertEqual(resumed, before)
    resumed.machine.end(at: t0 + 12 * 60_000)
    let a = try XCTUnwrap(straight.makeResult(early: true, endedAtEpochMs: 0))
    let b = try XCTUnwrap(resumed.makeResult(early: true, endedAtEpochMs: 0))
    XCTAssertEqual(a, b)
  }

  func testCrashAtEveryStepResumesAtThatStepAndSalvagesAllEarlierSplits() throws {
    for k in 0..<plan.steps.count {
      let id = "crash\(k)"
      let folder = try unfinishedFolder(id)
      var s = state(atStep: k)
      if plan.steps[k].activity == .wallBalls {
        _ = s.enterWallBalls(plan.steps[k])
        s.repCorrection = 1
        s.bank(step: plan.steps[k], repTimesMs: [11, 22, 33])
      }
      try CoachCheckpoint.write(checkpoint(id, s, seq: k), to: folder)
      // Relaunch: the same step, the same state.
      guard case let .valid(cp, _) = CoachCheckpoint.load(from: folder) else { return XCTFail("step \(k): checkpoint should load") }
      XCTAssertEqual(cp.state.machine.currentIndex, k, "step \(k)")
      XCTAssertEqual(cp.state, s, "step \(k)")
      // Resume failed: the splits still reach History.
      XCTAssertTrue(CoachCheckpoint.salvage(folder: folder, endedAtEpochMs: t0 + 3_600_000), "step \(k)")
      let r = try CoachResult.load(inSessionFolder: folder)
      XCTAssertTrue(r.early, "step \(k)")
      XCTAssertEqual(r.splits.count, k + 1, "step \(k)")
      XCTAssertEqual(r.splits.dropLast().compactMap(\.endMs).count, k, "step \(k)")
      XCTAssertNotNil(r.splits.last?.endMs, "the open step is closed")
      if plan.steps[k].activity == .wallBalls {
        XCTAssertEqual(r.repTimesMs, [11, 22, 33])
        XCTAssertEqual(r.repCorrection, 1)
      }
      XCTAssertEqual(try names(folder).contains(CoachCheckpoint.fileName), false, "checkpoint removed after salvage")
    }
  }

  func testCrashBetweenTheBackupCopyAndTheNewWriteStillLoadsTheBackup() throws {
    let id = "gap"
    let folder = try unfinishedFolder(id)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 2), seq: 1), to: folder)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 3), seq: 2), to: folder)
    // Crash after the old file was copied to .prev but before the new one landed: primary gone.
    try FileManager.default.removeItem(at: folder.appendingPathComponent(CoachCheckpoint.fileName))
    guard case let .valid(cp, usedBackup) = CoachCheckpoint.load(from: folder) else { return XCTFail("backup should load") }
    XCTAssertTrue(usedBackup)
    XCTAssertEqual(cp.state.machine.currentIndex, 2) // the write before the last
  }

  func testWriteLeavesOnlyTheTwoCheckpointFiles() throws {
    let id = "files"
    let folder = try unfinishedFolder(id)
    for n in 0..<4 { try CoachCheckpoint.write(checkpoint(id, state(atStep: n), seq: n), to: folder) }
    let ours = try names(folder).filter { $0.hasPrefix("coach-checkpoint") }
    XCTAssertEqual(ours, [CoachCheckpoint.fileName, CoachCheckpoint.previousFileName])
    guard case let .valid(cp, _) = CoachCheckpoint.load(from: folder) else { return XCTFail() }
    XCTAssertEqual(cp.seq, 3)
  }

  // MARK: Corrupt and partial checkpoints

  func testTruncatedLatestFallsBackToThePreviousCheckpoint() throws {
    let id = "trunc"
    let folder = try unfinishedFolder(id)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 4), seq: 1), to: folder)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 5), seq: 2), to: folder)
    let primary = folder.appendingPathComponent(CoachCheckpoint.fileName)
    let data = try Data(contentsOf: primary)
    try data.prefix(data.count / 2).write(to: primary) // a half-written file
    guard case let .valid(cp, usedBackup) = CoachCheckpoint.load(from: folder) else { return XCTFail("should fall back") }
    XCTAssertTrue(usedBackup)
    XCTAssertEqual(cp.seq, 1)
    XCTAssertEqual(cp.state.machine.currentIndex, 4)
  }

  func testACorruptPrimaryIsNotCopiedOverAGoodBackup() throws {
    let id = "keepgood"
    let folder = try unfinishedFolder(id)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 4), seq: 1), to: folder)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 5), seq: 2), to: folder)
    try Data("{ not json".utf8).write(to: folder.appendingPathComponent(CoachCheckpoint.fileName))
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 6), seq: 3), to: folder)
    let prev = try Data(contentsOf: folder.appendingPathComponent(CoachCheckpoint.previousFileName))
    let back = try JSONDecoder().decode(CoachCheckpoint.self, from: prev)
    XCTAssertEqual(back.seq, 1, "the good backup survives a corrupt primary")
  }

  func testGarbageEmptyAndMissingCheckpoints() throws {
    let id = "bad"
    let folder = try unfinishedFolder(id)
    XCTAssertEqual(CoachCheckpoint.load(from: folder), .none)
    let primary = folder.appendingPathComponent(CoachCheckpoint.fileName)
    for junk in [Data(), Data("{".utf8), Data("[]".utf8), Data("null".utf8), Data([0xFF, 0xFE, 0x00]), Data("{\"version\":1}".utf8)] {
      try junk.write(to: primary)
      guard case .unusable = CoachCheckpoint.load(from: folder) else { return XCTFail("junk should be unusable: \(junk)") }
    }
  }

  private func tampered(_ cp: CoachCheckpoint, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cp)) as? [String: Any])
    edit(&obj)
    return try JSONSerialization.data(withJSONObject: obj)
  }

  func testInconsistentCheckpointsAreRefusedRatherThanIndexedIntoThePlan() throws {
    let id = "tamper"
    let folder = try unfinishedFolder(id)
    let primary = folder.appendingPathComponent(CoachCheckpoint.fileName)
    let cp = checkpoint(id, state(atStep: 3))
    // A split naming a step the plan does not have.
    try tampered(cp) { obj in
      var st = obj["state"] as! [String: Any]
      var m = st["machine"] as! [String: Any]
      var splits = m["splits"] as! [[String: Any]]
      splits[0]["stepIndex"] = 999
      m["splits"] = splits
      st["machine"] = m
      obj["state"] = st
    }.write(to: primary)
    guard case .unusable = CoachCheckpoint.load(from: folder) else { return XCTFail("bad step index") }
    // Another session's checkpoint copied into this folder.
    try tampered(cp) { $0["sessionId"] = "someone-else" }.write(to: primary)
    guard case .unusable = CoachCheckpoint.load(from: folder) else { return XCTFail("wrong session id") }
    // A newer format than this build knows.
    try tampered(cp) { $0["version"] = CoachCheckpoint.currentVersion + 1 }.write(to: primary)
    guard case .unusable = CoachCheckpoint.load(from: folder) else { return XCTFail("future version") }
    // Two open splits.
    try tampered(cp) { obj in
      var st = obj["state"] as! [String: Any]
      var m = st["machine"] as! [String: Any]
      var splits = m["splits"] as! [[String: Any]]
      splits[0].removeValue(forKey: "endMs")
      m["splits"] = splits
      st["machine"] = m
      obj["state"] = st
    }.write(to: primary)
    guard case .unusable = CoachCheckpoint.load(from: folder) else { return XCTFail("two open splits") }
    // Control: the untouched checkpoint loads.
    try JSONEncoder().encode(cp).write(to: primary)
    guard case .valid = CoachCheckpoint.load(from: folder) else { return XCTFail("control should load") }
  }

  func testNewerOfTwoValidCopiesWins() throws {
    let id = "newer"
    let folder = try unfinishedFolder(id)
    let enc = JSONEncoder()
    try enc.encode(checkpoint(id, state(atStep: 2), seq: 5)).write(to: folder.appendingPathComponent(CoachCheckpoint.fileName))
    try enc.encode(checkpoint(id, state(atStep: 3), seq: 6)).write(to: folder.appendingPathComponent(CoachCheckpoint.previousFileName))
    guard case let .valid(cp, usedBackup) = CoachCheckpoint.load(from: folder) else { return XCTFail() }
    XCTAssertEqual(cp.seq, 6)
    XCTAssertTrue(usedBackup)
  }

  // MARK: closeUnfinished

  func testCloseUnfinishedWithACheckpointWritesACoachJSONHistoryAccepts() throws {
    let id = "close1"
    let folder = try unfinishedFolder(id)
    var s = state(atStep: 5)
    s.noRepLog.add(NoRepEvent(tMs: 4, setIndex: 0, stepIndex: 4))
    try CoachCheckpoint.write(checkpoint(id, s), to: folder)
    try SessionFiles.closeUnfinished(in: root, id: id)
    let r = try CoachResult.load(inSessionFolder: folder)
    let record = SessionRecord(id: id, result: r)
    XCTAssertFalse(record.isComplete)
    XCTAssertNil(record.targetWords, "no fake target line for an early session")
    XCTAssertEqual(r.splits.count, 6)
    XCTAssertEqual(r.noReps.count, 1)
    let m = try XCTUnwrap(SessionFiles.readManifest(folder))
    XCTAssertEqual(m.recovered, true)
    XCTAssertTrue(m.files?.contains(CoachResult.fileName) ?? false)
    XCTAssertFalse(m.files?.contains(CoachCheckpoint.fileName) ?? true, "the checkpoint is not shipped to the phone")
    XCTAssertFalse(m.files?.contains(CoachCheckpoint.previousFileName) ?? true)
  }

  func testCloseUnfinishedWithoutACheckpointStillJustClosesTheFolder() throws {
    let folder = try unfinishedFolder("plain")
    try SessionFiles.closeUnfinished(in: root, id: "plain")
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(CoachResult.fileName).path))
    XCTAssertEqual(SessionFiles.readManifest(folder)?.recovered, true)
  }

  func testCloseUnfinishedWithACorruptCheckpointDropsItAndCloses() throws {
    let folder = try unfinishedFolder("corrupt")
    try Data("{ half".utf8).write(to: folder.appendingPathComponent(CoachCheckpoint.fileName))
    try SessionFiles.closeUnfinished(in: root, id: "corrupt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(CoachResult.fileName).path))
    XCTAssertEqual(try names(folder).filter { $0.hasPrefix("coach-checkpoint") }, [])
    XCTAssertEqual(SessionFiles.readManifest(folder)?.recovered, true)
  }

  func testAnExistingCoachJSONIsNeverOverwrittenBySalvage() throws {
    let id = "keep"
    let folder = try unfinishedFolder(id)
    let finished = try XCTUnwrap(state(atStep: 3).makeResult(early: false, endedAtEpochMs: t0 + 999_999))
    let enc = JSONEncoder()
    let url = folder.appendingPathComponent(CoachResult.fileName)
    try enc.encode(finished).write(to: url)
    try CoachCheckpoint.write(checkpoint(id, state(atStep: 8)), to: folder)
    try SessionFiles.closeUnfinished(in: root, id: id)
    XCTAssertEqual(try CoachResult.load(inSessionFolder: folder), finished)
    XCTAssertEqual(try names(folder).filter { $0.hasPrefix("coach-checkpoint") }, [])
  }

  // MARK: Append-mode writer

  func testResumingWriterNeitherTruncatesNorRepeatsHeaders() throws {
    let w = try SessionWriter(root: root, manifest: manifest("ap1"))
    w.append(.hr, "1,100")
    w.append(.events, "2,start,x")
    w.flushAll()
    let manifestBefore = try XCTUnwrap(SessionFiles.readManifest(w.folder))
    XCTAssertNil(manifestBefore.resumed)
    let r = try SessionWriter(resuming: w.folder)
    r.append(.hr, "3,101")
    r.append(.events, "4,recovered_resume,ok")
    r.flushAll()
    XCTAssertEqual(try text(w.folder.appendingPathComponent("hr.csv")), "epoch_ms,bpm\n1,100\n3,101\n")
    XCTAssertEqual(try text(w.folder.appendingPathComponent("events.csv")), "epoch_ms,kind,detail\n2,start,x\n4,recovered_resume,ok\n")
    for stream in SessionStream.allCases {
      let body = try text(w.folder.appendingPathComponent(stream.fileName))
      XCTAssertEqual(body.components(separatedBy: stream.header).count, 2, "\(stream) header appears once")
    }
    XCTAssertEqual(SessionFiles.readManifest(w.folder), manifestBefore, "reopening alone does not count a resume")
    try r.markResumed()
    var expected = manifestBefore
    expected.resumed = 1 // the only change: one resume is counted
    XCTAssertEqual(SessionFiles.readManifest(w.folder), expected)
    XCTAssertEqual(r.manifest.sessionId, "ap1")
    let again = try SessionWriter(resuming: w.folder)
    try again.markResumed()
    XCTAssertEqual(again.manifest.resumed, 2)
    try again.finish(endedAtEpochMs: 9_000)
    XCTAssertEqual(SessionFiles.readManifest(w.folder)?.resumed, 2, "survives the finish rewrite")
  }

  func testResumingAfterAHalfWrittenLineStartsANewLine() throws {
    let w = try SessionWriter(root: root, manifest: manifest("ap2"))
    w.append(.hr, "1,100")
    w.flushAll()
    let url = w.folder.appendingPathComponent("hr.csv")
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data("2,10".utf8)) // killed mid-line
    try h.close()
    let r = try SessionWriter(resuming: w.folder)
    r.append(.hr, "3,101")
    r.flushAll()
    XCTAssertEqual(try text(url), "epoch_ms,bpm\n1,100\n2,10\n3,101\n")
  }

  func testResumingAFinishedOrMissingSessionThrows() throws {
    let w = try SessionWriter(root: root, manifest: manifest("ap3"))
    try w.finish(endedAtEpochMs: 9_000)
    XCTAssertThrowsError(try SessionWriter(resuming: w.folder))
    XCTAssertThrowsError(try SessionWriter(resuming: root.appendingPathComponent("nope")))
  }

  // MARK: Finding the session to resume

  func testLatestResumableOnlyEverConsidersTheNewestUnfinishedFolder() throws {
    let nowMs: Int64 = 100_000_000
    let fresh = nowMs - 60_000
    let older = "20260101T000000Z-aaaaaa", newer = "20260102T000000Z-bbbbbb"
    let olderFolder = try unfinishedFolder(older)
    try CoachCheckpoint.write(checkpoint(older, state(atStep: 2), savedAt: fresh), to: olderFolder)
    // Alone, the older folder is resumable.
    XCTAssertEqual(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs)?.folder.lastPathComponent, older)
    // A newer unfinished folder with no checkpoint (an uncoached recording, say): nothing resumes, never the older one.
    let newerFolder = try unfinishedFolder(newer)
    XCTAssertNil(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs))
    // A newer folder with an unreadable checkpoint: same.
    try Data("{ half".utf8).write(to: newerFolder.appendingPathComponent(CoachCheckpoint.fileName))
    XCTAssertNil(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs))
    // A newer folder with a good checkpoint wins.
    try CoachCheckpoint.write(checkpoint(newer, state(atStep: 3), savedAt: fresh), to: newerFolder)
    XCTAssertEqual(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs)?.folder.lastPathComponent, newer)
    XCTAssertEqual(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs)?.checkpoint.state.machine.currentIndex, 3)
  }

  func testLatestResumableSkipsFinishedStaleAndAlreadySavedSessions() throws {
    let nowMs: Int64 = 100_000_000
    let fresh = nowMs - 60_000
    // Stale checkpoint.
    let stale = try unfinishedFolder("20260102T000000Z-bbbbbb")
    try CoachCheckpoint.write(checkpoint("20260102T000000Z-bbbbbb", state(atStep: 2), savedAt: nowMs - CoachCheckpoint.maxResumeAgeMs - 1), to: stale)
    XCTAssertNil(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs))
    try FileManager.default.removeItem(at: stale)
    // Already has coach.json (crash inside the finish-undo window).
    let saved = try unfinishedFolder("20260103T000000Z-cccccc")
    try CoachCheckpoint.write(checkpoint("20260103T000000Z-cccccc", state(atStep: 2), savedAt: fresh), to: saved)
    try JSONEncoder().encode(try XCTUnwrap(state(atStep: 2).makeResult(early: true, endedAtEpochMs: 1))).write(to: saved.appendingPathComponent(CoachResult.fileName))
    XCTAssertNil(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs))
    try FileManager.default.removeItem(at: saved)
    // Finished sessions are not unfinished.
    let done = try SessionWriter(root: root, manifest: manifest("20260104T000000Z-dddddd"))
    try CoachCheckpoint.write(checkpoint("20260104T000000Z-dddddd", state(atStep: 2), savedAt: fresh), to: done.folder)
    try done.finish(endedAtEpochMs: 9_000)
    XCTAssertNil(CoachCheckpoint.latestResumable(in: root, nowMs: nowMs))
  }

  // MARK: Thermal

  func testThermalLabelsAreTheFourReportValues() {
    XCTAssertEqual(ThermalLog.label(.nominal), "nominal")
    XCTAssertEqual(ThermalLog.label(.fair), "fair")
    XCTAssertEqual(ThermalLog.label(.serious), "serious")
    XCTAssertEqual(ThermalLog.label(.critical), "critical")
    XCTAssertEqual(ThermalLog.kind, "thermal")
  }
}
