import XCTest
@testable import CoachKit

final class WallBallCounterTests: XCTestCase {
  /// 100 Hz magnitude (g): small noise, plus a 0.3 s half-sine burst of `amp` at each burst time.
  /// `doubleBump` adds a second burst 0.35 s later, like a throw and a catch.
  private func signal(bursts: [Double], amp: Double, duration: Double, doubleBump: Bool = false) -> [(Double, Double)] {
    var seed: UInt64 = 42
    var out: [(Double, Double)] = []
    for i in 0..<Int(duration * 100) {
      let t = Double(i) / 100
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      var m = 0.05 + Double(seed >> 33) / Double(1 << 31) * 0.08
      for b in bursts {
        for off in (doubleBump ? [0.0, 0.35] : [0.0]) {
          let p = t - (b + off)
          if p >= 0, p < 0.3 { m += amp * sin(.pi * p / 0.3) }
        }
      }
      out.append((t, m))
    }
    return out
  }

  private func run(_ s: [(Double, Double)]) -> WallBallCounter {
    var c = WallBallCounter()
    for (t, m) in s { c.add(t: t, magnitude: m) }
    return c
  }

  private func every(_ interval: Double, count: Int, from: Double = 1) -> [Double] {
    (0..<count).map { from + Double($0) * interval }
  }

  func testCountsEveryRepAtASteadyRhythm() {
    let c = run(signal(bursts: every(3, count: 10), amp: 1.5, duration: 34))
    XCTAssertEqual(c.count, 10)
    XCTAssertEqual(c.confidence, .high)
  }

  func testCountsAFastRhythm() {
    let c = run(signal(bursts: every(2, count: 15), amp: 1.5, duration: 33))
    XCTAssertEqual(c.count, 15)
  }

  func testDoubleBumpPerRepCountsOnce() {
    let c = run(signal(bursts: every(3, count: 8), amp: 1.5, duration: 27, doubleBump: true))
    XCTAssertEqual(c.count, 8)
  }

  func testRestBetweenSetsDoesNotAddReps() {
    let burst = every(3, count: 5) + every(3, count: 5, from: 40)
    let c = run(signal(bursts: burst, amp: 1.5, duration: 60))
    XCTAssertEqual(c.count, 10)
    XCTAssertEqual(c.confidence, .high) // the long gap is a rest, not an uneven rhythm
  }

  func testNoiseAndSmallMovementCountNothing() {
    XCTAssertEqual(run(signal(bursts: [], amp: 1, duration: 30)).count, 0)
    XCTAssertEqual(run(signal(bursts: every(3, count: 8), amp: 0.3, duration: 27)).count, 0)
  }

  func testConfidenceIsLowUntilThreeReps() {
    let c = run(signal(bursts: every(3, count: 2), amp: 1.5, duration: 8))
    XCTAssertEqual(c.count, 2)
    XCTAssertEqual(c.confidence, .low)
  }

  func testUnevenRhythmIsLowConfidence() {
    var t = 1.0
    var bursts: [Double] = []
    for i in 0..<8 { bursts.append(t); t += i % 2 == 0 ? 1.4 : 4.0 }
    let c = run(signal(bursts: bursts, amp: 1.5, duration: t + 2))
    XCTAssertEqual(c.count, 8)
    XCTAssertEqual(c.confidence, .low)
  }

  func testRepTimesAreRecordedInOrder() {
    let c = run(signal(bursts: every(3, count: 4), amp: 1.5, duration: 15))
    XCTAssertEqual(c.repTimes.count, 4)
    XCTAssertTrue(zip(c.repTimes.dropFirst(), c.repTimes).allSatisfy { $0 - $1 > 2.5 })
  }
}
