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

  func testHeartbeatsKeepOneBigFileFromFailing() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    for t in stride(from: 30.0, through: 900, by: 30) { // one large file outstanding for 15 minutes
      w.activity(session: "s1", at: t)
      XCTAssertNil(w.failedSession(now: t + 29, openSince: 0), "still sending at \(t)")
    }
    XCTAssertEqual(w.failedSession(now: 900 + 181, openSince: 0), "s1") // heartbeats stop: it fails
  }

  func testOnceAFileHasArrivedTheGraceIsFifteenMinutes() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    w.fileArrived(session: "s1", at: 100)
    XCTAssertNil(w.failedSession(now: 100 + 899, openSince: 0)) // the watch app is suspended, no heartbeats
    XCTAssertEqual(w.failedSession(now: 100 + 901, openSince: 0), "s1")
    w.fileArrived(session: "s1", at: 1000) // each further file restarts it
    XCTAssertNil(w.failedSession(now: 1000 + 899, openSince: 0))
  }

  func testAFileForAnUnknownSessionIsIgnoredAndCompleteResetsTheGrace() {
    var w = SyncWatchdog()
    w.fileArrived(session: "x", at: 5)
    XCTAssertTrue(w.pending.isEmpty)
    w.finished(session: "s1", at: 0)
    w.fileArrived(session: "s1", at: 1)
    w.complete(session: "s1")
    w.finished(session: "s1", at: 2000)
    XCTAssertEqual(w.failedSession(now: 2000 + 181, openSince: 0), "s1") // back to the 3-minute grace
  }

  func testEntriesExpireAfterADay() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    XCTAssertEqual(w.failedSession(now: 86_000, openSince: 0), "s1")
    XCTAssertNil(w.failedSession(now: 86_401, openSince: 0))
    w.prune(now: 86_401)
    XCTAssertTrue(w.pending.isEmpty)
  }

  func testTheNewestStuckSessionIsTheOneReported() {
    var w = SyncWatchdog()
    w.finished(session: "20261026T100000Z-aaaaaa", at: 0)
    w.finished(session: "20261026T120000Z-bbbbbb", at: 10)
    XCTAssertEqual(w.failedSession(now: 500, openSince: 0), "20261026T120000Z-bbbbbb")
  }

  func testANewerCompleteResultBeatsAnOlderFailure() {
    XCTAssertFalse(SyncWatchdog.showsFailed(failedId: nil, newestReadyId: "b"))
    XCTAssertTrue(SyncWatchdog.showsFailed(failedId: "b", newestReadyId: nil))
    XCTAssertTrue(SyncWatchdog.showsFailed(failedId: "b", newestReadyId: "a")) // the ready one is older: failed shows
    XCTAssertFalse(SyncWatchdog.showsFailed(failedId: "a", newestReadyId: "b")) // a newer complete session wins
  }

  func testAWatchSideDeleteClearsIt() {
    var w = SyncWatchdog()
    w.finished(session: "s1", at: 0)
    w.complete(session: "s1") // what the phone does on a "gone" notice or a local delete
    XCTAssertNil(w.failedSession(now: 10_000, openSince: 0))
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
