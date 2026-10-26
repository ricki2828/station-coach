import XCTest
@testable import CoachKit

final class LabelLogTests: XCTestCase {
  func testSetAndCurrent() {
    var log = LabelLog()
    XCTAssertNil(log.current)
    let e = log.set(.run, at: 1_000)
    XCTAssertEqual(e, LabelEvent(kind: .set, epochMs: 1_000, activity: .run))
    XCTAssertEqual(log.current, .run)
  }

  func testRepeatTapIsNoOp() {
    var log = LabelLog()
    log.set(.run, at: 0)
    XCTAssertNil(log.set(.run, at: 500))
    XCTAssertEqual(log.intervals(endMs: 1_000).count, 1)
  }

  func testUndoRestoresPreviousAndExtendsIt() {
    var log = LabelLog()
    log.set(.wallBalls, at: 0)
    log.set(.rest, at: 600)
    let undone = log.undo(at: 630)
    XCTAssertEqual(undone, LabelEvent(kind: .undo, epochMs: 630, activity: .rest))
    XCTAssertEqual(log.current, .wallBalls)
    XCTAssertEqual(log.intervals(endMs: 1_000), [LabelInterval(activity: .wallBalls, startMs: 0, endMs: 1_000)])
  }

  func testUndoOnEmptyIsNil() {
    var log = LabelLog()
    XCTAssertNil(log.undo(at: 5))
  }

  func testIntervalsRunToNextLabelAndEnd() {
    var log = LabelLog()
    log.set(.run, at: 0)
    log.set(.transition, at: 100)
    log.set(.skierg, at: 150)
    XCTAssertEqual(log.intervals(endMs: 400), [
      LabelInterval(activity: .run, startMs: 0, endMs: 100),
      LabelInterval(activity: .transition, startMs: 100, endMs: 150),
      LabelInterval(activity: .skierg, startMs: 150, endMs: 400),
    ])
  }

  func testReplayMatchesLiveState() {
    var live = LabelLog()
    var events: [LabelEvent] = []
    events.append(contentsOf: [live.set(.run, at: 0), live.set(.row, at: 10), live.undo(at: 12), live.set(.skierg, at: 20)].compactMap { $0 })
    let replayed = LabelLog.replay(events)
    XCTAssertEqual(replayed.intervals(endMs: 50), live.intervals(endMs: 50))
  }

  func testCsvLine() {
    XCTAssertEqual(LabelEvent(kind: .set, epochMs: 42, activity: .sledPush).csvLine, "42,set,sled_push")
  }

  func testTenCoachedActivitiesPlusRest() {
    XCTAssertEqual(Activity.coached.count, 10)
    XCTAssertEqual(Activity.allCases.count, 11)
  }
}
