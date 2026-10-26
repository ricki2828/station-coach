import XCTest
@testable import CoachKit

final class WallBallCounterTests: XCTestCase {
  /// 100 Hz magnitude (g): small noise, plus a 0.3 s half-sine burst of `amp` at each burst time.
  /// `catchDelay` adds a second burst that long after each one: the catch after the throw.
  private func signal(bursts: [Double], amp: Double, duration: Double, catchDelay: Double? = nil) -> [(Double, Double)] {
    var seed: UInt64 = 42
    var out: [(Double, Double)] = []
    for i in 0..<Int(duration * 100) {
      let t = Double(i) / 100
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      var m = 0.05 + Double(seed >> 33) / Double(1 << 31) * 0.08
      for b in bursts {
        for off in (catchDelay.map { [0.0, $0] } ?? [0.0]) {
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

  private func every(_ interval: Double, count: Int, from: Double = 5) -> [Double] {
    (0..<count).map { from + Double($0) * interval }
  }

  func testCountsEveryRepAtASteadyRhythm() {
    let c = run(signal(bursts: every(3, count: 10), amp: 1.5, duration: 34))
    XCTAssertEqual(c.count, 10)
    XCTAssertEqual(c.confidence, .high)
  }

  func testCountsAFastRhythm() {
    let c = run(signal(bursts: every(2, count: 15), amp: 1.5, duration: 38))
    XCTAssertEqual(c.count, 15)
  }

  func testCatchPeakAfterTheThrowIsNotACountedRep() {
    for delay in [0.35, 1.0, 1.3, 1.5] {
      let c = run(signal(bursts: every(3, count: 8), amp: 1.5, duration: 34, catchDelay: delay))
      XCTAssertEqual(c.count, 8, "catch \(delay) s after the throw")
    }
    // fast reps: the next throw comes 2 s after the last, 0.5 s after a 1.5 s catch
    let fast = run(signal(bursts: every(2, count: 10), amp: 1.5, duration: 30, catchDelay: 1.3))
    XCTAssertEqual(fast.count, 10)
  }

  func testJoggingIntoTheStationIsIgnored() {
    let jog = (0..<8).map { 0.5 + Double($0) * 0.4 } // arm swing at 2.5 Hz, up to 3.3 s
    let c = run(signal(bursts: jog + every(3, count: 6), amp: 1.5, duration: 30))
    XCTAssertEqual(c.count, 6)
  }

  func testEarlyPeaksAreSkippedAndLaterOnesCounted() {
    let c = run(signal(bursts: [1.0, 5.0], amp: 1.5, duration: 9))
    XCTAssertEqual(c.count, 1)
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
    let c = run(signal(bursts: every(3, count: 2), amp: 1.5, duration: 12))
    XCTAssertEqual(c.count, 2)
    XCTAssertEqual(c.confidence, .low)
  }

  func testUnevenRhythmIsLowConfidence() {
    var t = 5.0
    var bursts: [Double] = []
    for i in 0..<8 { bursts.append(t); t += i % 2 == 0 ? 2.0 : 5.2 }
    let c = run(signal(bursts: bursts, amp: 1.5, duration: t + 2))
    XCTAssertEqual(c.count, 8)
    XCTAssertEqual(c.confidence, .low)
  }

  func testRepTimesAreRecordedInOrder() {
    let c = run(signal(bursts: every(3, count: 4), amp: 1.5, duration: 20))
    XCTAssertEqual(c.repTimes.count, 4)
    XCTAssertTrue(zip(c.repTimes.dropFirst(), c.repTimes).allSatisfy { $0 - $1 > 2.5 })
  }
}
