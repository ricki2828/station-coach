import XCTest
@testable import CoachKit

final class SessionMachineTests: XCTestCase {
  private func machine() -> SessionMachine {
    SessionMachine(plan: PlanBuilder.build(division: .openMen, target: 4800, type: .fullSim))
  }

  func testReadyUntilStarted() {
    var m = machine()
    XCTAssertEqual(m.phase, .ready)
    XCTAssertNil(m.current)
    XCTAssertEqual(m.advance(at: 0), .notRunning)
    m.start(at: 1_000)
    XCTAssertEqual(m.phase, .running)
    XCTAssertEqual(m.currentIndex, 0)
    XCTAssertEqual(m.next?.activity, .skierg)
  }

  func testAdvanceWalksThroughEveryStepThenFinishes() {
    var m = machine()
    m.start(at: 0)
    var t: Int64 = 0
    for i in 1..<16 {
      t += 10_000
      XCTAssertEqual(m.advance(at: t), .started(i))
    }
    t += 10_000
    XCTAssertEqual(m.advance(at: t), .finished)
    XCTAssertEqual(m.phase, .finished(early: false))
    XCTAssertEqual(m.splits.count, 16)
    XCTAssertTrue(m.splits.allSatisfy { $0.endMs != nil })
    XCTAssertEqual(m.totalElapsedSeconds(at: t + 99_000), 160)
    XCTAssertEqual(m.advance(at: t + 10_000), .notRunning)
  }

  func testDoubleFireWithinThreeSecondsIsIgnored() {
    var m = machine()
    m.start(at: 0)
    XCTAssertEqual(m.advance(at: 300_000), .started(1))
    XCTAssertEqual(m.advance(at: 301_000), .ignored)
    XCTAssertEqual(m.currentIndex, 1)
    XCTAssertEqual(m.advance(at: 304_000), .started(2))
  }

  func testUndoReopensThePreviousStep() {
    var m = machine()
    m.start(at: 0)
    XCTAssertFalse(m.undo(at: 5_000)) // nothing before step 0
    m.advance(at: 300_000)
    XCTAssertTrue(m.undo(at: 301_000))
    XCTAssertEqual(m.currentIndex, 0)
    XCTAssertNil(m.splits.last?.endMs)
    XCTAssertEqual(m.splits.count, 1)
    // undo clears the debounce so the right press goes through
    XCTAssertEqual(m.advance(at: 302_000), .started(1))
  }

  func testUndoFromFinishedResumesTheLastStep() {
    var m = machine()
    m.start(at: 0)
    for i in 1...16 { m.advance(at: Int64(i) * 10_000) }
    XCTAssertEqual(m.phase, .finished(early: false))
    XCTAssertTrue(m.undo(at: 170_000))
    XCTAssertEqual(m.phase, .running)
    XCTAssertEqual(m.currentIndex, 15)
    XCTAssertNil(m.endMs)
  }

  func testEarlyEndKeepsWhatIsDone() {
    var m = machine()
    m.start(at: 0)
    m.advance(at: 300_000)
    m.advance(at: 600_000)
    m.end(at: 700_000)
    XCTAssertEqual(m.phase, .finished(early: true))
    XCTAssertEqual(m.splits.count, 3)
    XCTAssertEqual(m.splits.last?.endMs, 700_000)
    XCTAssertEqual(m.totalElapsedSeconds(at: 999_000), 700)
  }

  func testDeltaCountsFinishedStepsAndOverrunOnly() {
    var m = machine()
    m.start(at: 0)
    XCTAssertEqual(m.deltaSeconds(at: 100_000), 0) // inside the 324 s target
    m.advance(at: 300_000) // run 1 took 300 vs 324: 24 ahead
    XCTAssertEqual(m.deltaSeconds(at: 310_000), -24)
    XCTAssertEqual(m.deltaSeconds(at: 300_000 + 275_000), -14) // ski 275 vs 265: 10 over
  }

  func testLabelStartsRunsAfterStationsAsTransition() {
    var m = machine()
    m.start(at: 0)
    XCTAssertEqual(m.label(at: 1_000), .run) // run 1 has nothing before it
    m.advance(at: 300_000)
    XCTAssertEqual(m.label(at: 310_000), .skierg)
    m.advance(at: 600_000)
    XCTAssertEqual(m.label(at: 605_000), .transition)
    XCTAssertEqual(m.label(at: 620_000), .run)
  }
}
