import XCTest
@testable import CoachKit

final class RateTests: XCTestCase {
  func testHzFromTimestamps() {
    var m = RateMeter()
    for i in 0..<101 { m.add(Double(i) * 0.01) }
    XCTAssertEqual(m.count, 101)
    XCTAssertEqual(m.hz ?? 0, 100, accuracy: 0.001)
  }

  func testHzNilUntilTwoSamples() {
    var m = RateMeter()
    XCTAssertNil(m.hz)
    m.add(1)
    XCTAssertNil(m.hz)
  }

  func testResetClears() {
    var m = RateMeter()
    m.add(0); m.add(1)
    m.reset()
    XCTAssertEqual(m.count, 0)
    XCTAssertNil(m.hz)
  }

  func testDecimatorDownsamples800To100() {
    var d = Decimator(targetHz: 100)
    var kept = RateMeter()
    for i in 0..<(800 * 5) {
      let t = Double(i) / 800
      if d.keep(t) { kept.add(t) }
    }
    XCTAssertEqual(kept.hz ?? 0, 100, accuracy: 15)
    XCTAssertGreaterThanOrEqual(kept.hz ?? 0, 50)
  }

  func testDecimatorKeepsEverythingAtOrBelowTarget() {
    var d = Decimator(targetHz: 100)
    var n = 0
    for i in 0..<100 {
      if d.keep(Double(i) * 0.02) { n += 1 }
    }
    XCTAssertEqual(n, 100)
  }
}
