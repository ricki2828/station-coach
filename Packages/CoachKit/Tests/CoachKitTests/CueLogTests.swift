import XCTest
@testable import CoachKit

final class CueLogTests: XCTestCase {
  private func ev(_ id: Int, _ kind: CueEvent.Kind, mode: CueEvent.Mode = .speech, hp: Bool = true) -> CueEvent {
    CueEvent(epochMs: Int64(id) * 1000, cueId: id, kind: kind, mode: mode, headphones: hp, outputs: ["BluetoothA2DPOutput/AirPods"], phrase: "go")
  }

  func testStatsCountDeliveredHapticAndMissed() {
    let events = [
      ev(1, .issued), ev(1, .finished),
      ev(2, .issued), ev(2, .finished), ev(2, .missed),
      ev(3, .issued, mode: .hapticOnly, hp: false),
      ev(4, .issued), ev(4, .timeout),
    ]
    let s = CueLog.stats(events)
    XCTAssertEqual(s, CueStats(issued: 4, delivered: 1, hapticOnly: 1, missed: 1))
    XCTAssertEqual(s.deliveryPercent, 25, accuracy: 0.001)
  }

  func testEmptyIsZeroPercent() {
    XCTAssertEqual(CueLog.stats([]).deliveryPercent, 0)
  }

  func testCsvLineQuotesFieldsWithCommas() {
    let e = CueEvent(epochMs: 5, cueId: 2, kind: .issued, mode: .hapticOnly, headphones: false, outputs: ["Speaker/Watch, built-in", "x"], phrase: "a \"b\"", detail: "")
    XCTAssertEqual(e.csvLine, "5,2,issued,haptic_only,0,\"Speaker/Watch, built-in;x\",\"a \"\"b\"\"\",")
  }

  func testHeaderColumnCountMatchesLine() {
    let e = ev(1, .issued)
    XCTAssertEqual(CueEvent.csvHeader.split(separator: ",").count, 8)
    XCTAssertEqual(e.csvLine.split(separator: ",", omittingEmptySubsequences: false).count, 8)
  }

  func testRouteClassifier() {
    XCTAssertTrue(RouteClassifier.isHeadphones(portTypes: ["BluetoothA2DPOutput"]))
    XCTAssertTrue(RouteClassifier.isHeadphones(portTypes: ["BuiltInSpeaker", "Headphones"]))
    XCTAssertFalse(RouteClassifier.isHeadphones(portTypes: ["BuiltInSpeaker"]))
    XCTAssertFalse(RouteClassifier.isHeadphones(portTypes: []))
  }

  func testPhraseIndexWraps() {
    XCTAssertEqual(CuePhrases.phrase(at: 0), CuePhrases.phrase(at: CuePhrases.all.count))
    XCTAssertEqual(CuePhrases.phrase(at: -1), CuePhrases.all.last)
  }
}
