import XCTest
@testable import CoachKit

final class HeartRateWatchTests: XCTestCase {
  func testNotOffBeforeStart() {
    XCTAssertFalse(HeartRateWatch().isOff(at: 500))
  }

  func testOffWhenNoSampleWithinTwentySeconds() {
    var w = HeartRateWatch()
    w.start(at: 100)
    XCTAssertFalse(w.isOff(at: 119))
    XCTAssertFalse(w.isOff(at: 120))
    XCTAssertTrue(w.isOff(at: 120.5))
  }

  func testFirstSampleInTimeKeepsItOn() {
    var w = HeartRateWatch()
    w.start(at: 0)
    w.sample(at: 15)
    XCTAssertFalse(w.isOff(at: 30)) // the 20 s rule no longer applies once a sample has come
    XCTAssertTrue(w.everSampled)
  }

  func testOffAfterSixtySecondsOfSilence() {
    var w = HeartRateWatch()
    w.start(at: 0)
    w.sample(at: 10)
    XCTAssertFalse(w.isOff(at: 70))
    XCTAssertTrue(w.isOff(at: 70.5))
  }

  func testASampleClearsOff() {
    var w = HeartRateWatch()
    w.start(at: 0)
    XCTAssertTrue(w.isOff(at: 30))
    w.sample(at: 31)
    XCTAssertFalse(w.isOff(at: 32))
  }

  func testStartResetsAndStopSilences() {
    var w = HeartRateWatch()
    w.start(at: 0)
    w.sample(at: 5)
    w.start(at: 1000)
    XCTAssertFalse(w.everSampled)
    XCTAssertFalse(w.isOff(at: 1010))
    w.stop()
    XCTAssertFalse(w.isOff(at: 5000))
  }

  func testMissedEntireSession() {
    var w = HeartRateWatch()
    w.start(at: 0)
    XCTAssertFalse(w.missedEntireSession(endingAt: 10)) // too short to say
    XCTAssertTrue(w.missedEntireSession(endingAt: 300))
    w.sample(at: 40)
    XCTAssertFalse(w.missedEntireSession(endingAt: 300))
  }
}
