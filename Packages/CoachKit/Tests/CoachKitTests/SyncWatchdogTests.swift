import XCTest
@testable import CoachKit

final class SyncWatchdogTests: XCTestCase {
  func testNothingWaitingNeverFails() {
    XCTAssertNil(SyncWatchdog().failedSession(now: 10_000, openSince: 0))
  }

  func testFailsAfterThreeMinutesWithNoFile() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 100)
    XCTAssertNil(w.failedSession(now: 280, openSince: 0)) // exactly 180 s
    XCTAssertEqual(w.failedSession(now: 281, openSince: 0), "s1")
  }

  func testACompleteSessionClearsIt() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    XCTAssertEqual(w.failedSession(now: 400, openSince: 0), "s1")
    w.complete(session: "s1")
    XCTAssertNil(w.failedSession(now: 400, openSince: 0))
    XCTAssertTrue(w.pending.isEmpty)
  }

  func testAFileRestartsTheClock() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    w.activity(session: "s1", at: 170)
    XCTAssertNil(w.failedSession(now: 340, openSince: 0))
    XCTAssertEqual(w.failedSession(now: 351, openSince: 0), "s1")
  }

  func testTimeWithTheAppClosedDoesNotCount() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    XCTAssertNil(w.failedSession(now: 5_050, openSince: 5_000)) // opened 50 s ago
    XCTAssertEqual(w.failedSession(now: 5_181, openSince: 5_000), "s1")
  }

  func testActivityForAnUnknownSessionIsIgnored() {
    var w = SyncWatchdog()
    w.activity(session: "other", at: 5)
    XCTAssertTrue(w.pending.isEmpty)
  }

  func testRoundTripsThroughJSON() throws {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 7)
    let back = try JSONDecoder().decode(SyncWatchdog.self, from: JSONEncoder().encode(w))
    XCTAssertEqual(back, w)
  }
}
