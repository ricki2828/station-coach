import XCTest
@testable import CoachKit

final class NoRepLogTests: XCTestCase {
  private func event(_ t: Int64, set: Int = 0, step: Int = 3) -> NoRepEvent { NoRepEvent(tMs: t, setIndex: set, stepIndex: step) }

  func testCountIsPerStep() {
    var log = NoRepLog()
    log.add(event(1)); log.add(event(2)); log.add(event(3, step: 9))
    XCTAssertEqual(log.count(inStep: 3), 2)
    XCTAssertEqual(log.count(inStep: 9), 1)
  }

  func testUndoRemovesTheLatestTapOfThatStepAndLowersTheCount() {
    var log = NoRepLog()
    log.add(event(1, set: 1)); log.add(event(2, set: 2)); log.add(event(3, step: 9))
    XCTAssertEqual(log.undoLast(inStep: 3)?.tMs, 2)
    XCTAssertEqual(log.count(inStep: 3), 1)
    XCTAssertEqual(log.count(inStep: 9), 1)
    XCTAssertEqual(log.events.map(\.tMs), [1, 3])
  }

  func testUndoWithNothingToUndoChangesNothing() {
    var log = NoRepLog()
    log.add(event(1, step: 9))
    XCTAssertNil(log.undoLast(inStep: 3))
    XCTAssertEqual(log.events.count, 1)
  }

  /// Reps left on the watch is count + correction - taps: undoing a tap puts reps left back where it was.
  func testUndoRestoresRepsLeft() {
    var log = NoRepLog()
    let total = 100, thrown = 100
    func left() -> Int { total - max(0, thrown - log.count(inStep: 3)) }
    XCTAssertEqual(left(), 0)
    log.add(event(1))
    XCTAssertEqual(left(), 1)
    log.undoLast(inStep: 3)
    XCTAssertEqual(left(), 0)
  }
}
