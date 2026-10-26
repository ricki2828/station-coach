import XCTest
@testable import CoachKit

final class NoRepRestTests: XCTestCase {
  private let sets = [15, 15, 15]

  func testSetEndShowsAfterTheCountSettlesNotBefore() {
    var r = NoRepRest(count: 0, nowMs: 0)
    XCTAssertFalse(r.update(nowMs: 10_000, count: 15, done: 15, sets: sets)) // rep 15 just counted
    XCTAssertFalse(r.update(nowMs: 11_000, count: 15, done: 15, sets: sets))
    XCTAssertTrue(r.update(nowMs: 11_500, count: 15, done: 15, sets: sets))
  }

  func testSlowRepMidSetNeverShowsBeforeFourSeconds() {
    var r = NoRepRest(count: 0, nowMs: 0)
    r.update(nowMs: 1_000, count: 6, done: 6, sets: sets)
    XCTAssertFalse(r.update(nowMs: 4_900, count: 6, done: 6, sets: sets)) // 3.9 s: a slow rep
    XCTAssertTrue(r.update(nowMs: 5_000, count: 6, done: 6, sets: sets))
  }

  func testSlowRepsDoNotFlicker() {
    var r = NoRepRest(count: 0, nowMs: 0)
    r.update(nowMs: 0, count: 5, done: 5, sets: sets)
    var shownAt: [Int64] = []
    for t in stride(from: Int64(0), through: 3_900, by: 100) where r.update(nowMs: t, count: 5, done: 5, sets: sets) { shownAt.append(t) }
    XCTAssertTrue(shownAt.isEmpty)
  }

  func testResumeHidesOnlyOnTheNextCountedRep() {
    var r = NoRepRest(count: 0, nowMs: 0)
    r.update(nowMs: 0, count: 15, done: 15, sets: sets)
    XCTAssertTrue(r.update(nowMs: 5_000, count: 15, done: 15, sets: sets))
    XCTAssertTrue(r.update(nowMs: 9_000, count: 15, done: 15, sets: sets)) // still resting: stays
    XCTAssertFalse(r.update(nowMs: 9_100, count: 16, done: 16, sets: sets))
    XCTAssertFalse(r.update(nowMs: 11_000, count: 16, done: 16, sets: sets)) // 1.9 s after: mid-set, not yet
  }

  func testNothingShownBeforeTheFirstRep() {
    var r = NoRepRest(count: 0, nowMs: 0)
    XCTAssertFalse(r.update(nowMs: 60_000, count: 0, done: 0, sets: sets))
  }

  func testUndoStaysForItsWindowEvenWhenThrowingResumes() {
    var r = NoRepRest(count: 15, nowMs: 0)
    r.update(nowMs: 5_000, count: 15, done: 15, sets: sets)
    r.noted(nowMs: 6_000)
    XCTAssertTrue(r.undoVisible(nowMs: 6_100, taps: 1))
    XCTAssertFalse(r.update(nowMs: 7_000, count: 16, done: 16, sets: sets)) // button hides
    XCTAssertTrue(r.undoVisible(nowMs: 9_900, taps: 1)) // chip still up
    XCTAssertFalse(r.undoVisible(nowMs: 10_000, taps: 1)) // 4 s gone
  }

  func testUndoNeedsATapAndClears() {
    var r = NoRepRest()
    r.noted(nowMs: 0)
    XCTAssertFalse(r.undoVisible(nowMs: 100, taps: 0))
    r.clearUndo()
    XCTAssertFalse(r.undoVisible(nowMs: 100, taps: 1))
  }

  func testResetHidesAndRestartsTheClock() {
    var r = NoRepRest(count: 0, nowMs: 0)
    r.update(nowMs: 0, count: 3, done: 3, sets: sets)
    r.update(nowMs: 5_000, count: 3, done: 3, sets: sets)
    XCTAssertTrue(r.shown)
    r.reset(count: 3, nowMs: 20_000)
    XCTAssertFalse(r.update(nowMs: 21_000, count: 3, done: 3, sets: sets))
  }

  func testNoRepCueBypassesTheGapButNotStaleness() {
    var s = CueScheduler()
    s.offer(CoachCue(kind: .wallBallSet, text: "set", createdAt: 0))
    XCTAssertNotNil(s.next(at: 0, speaking: false))
    s.offer(CoachCue(kind: .noRep, text: "No rep noted.", createdAt: 2))
    XCTAssertEqual(s.next(at: 2, speaking: false)?.kind, .noRep) // 2 s after another cue
    s.offer(CoachCue(kind: .noRep, text: "No rep noted.", createdAt: 10))
    XCTAssertNil(s.next(at: 16, speaking: false)) // could not start within 5 s: dropped
  }

  func testNoRepCueWaitsForSpeechToEnd() {
    var s = CueScheduler()
    s.offer(CoachCue(kind: .noRep, text: "x", createdAt: 0))
    XCTAssertNil(s.next(at: 1, speaking: true))
    XCTAssertNotNil(s.next(at: 2, speaking: false))
  }
}
