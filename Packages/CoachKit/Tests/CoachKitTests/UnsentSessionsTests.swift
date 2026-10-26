import XCTest
@testable import CoachKit

final class UnsentSessionsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_016_000) // Mon 26 Oct 2026, 12:00 UTC

  func testSessionIdStartDate() {
    XCTAssertEqual(UnsentSessions.startDate(ofSessionId: "20261026T100000Z-ab12cd"), Date(timeIntervalSince1970: 1_793_008_800))
    XCTAssertNil(UnsentSessions.startDate(ofSessionId: "not-a-session"))
  }

  func testFreshPartialFolderCounts() {
    XCTAssertTrue(UnsentSessions.hasUnsent(partialIds: ["20261025T100000Z-aaaaaa"], pendingIds: [], now: now))
  }

  func testAbandonedPartialFolderDoesNotStickForever() {
    XCTAssertFalse(UnsentSessions.hasUnsent(partialIds: ["20260901T100000Z-aaaaaa", "20261010T080000Z-bbbbbb"], pendingIds: [], now: now))
  }

  func testUnparseableOrFutureIdsAreIgnored() {
    XCTAssertFalse(UnsentSessions.hasUnsent(partialIds: ["junk", "20271026T100000Z-cccccc"], pendingIds: [], now: now))
  }

  func testWatchdogPendingAlwaysCounts() {
    XCTAssertTrue(UnsentSessions.hasUnsent(partialIds: [], pendingIds: ["20261020T100000Z-dddddd"], now: now))
    XCTAssertFalse(UnsentSessions.hasUnsent(partialIds: [], pendingIds: [], now: now))
  }

  func testNoRescheduleUntilTheFirstLoadHasLanded() {
    var gate = NoticeRescheduleGate()
    XCTAssertFalse(gate.mayReschedule)
    gate.loadLanded()
    XCTAssertTrue(gate.mayReschedule)
  }
}
