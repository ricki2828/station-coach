import XCTest
@testable import CoachKit

final class CueSchedulerTests: XCTestCase {
  private func cue(_ kind: CoachCueKind, _ text: String, at t: TimeInterval) -> CoachCue {
    CoachCue(kind: kind, text: text, createdAt: t)
  }

  func testFirstCueGoesOutAndTheGapHoldsTheNext() {
    var s = CueScheduler()
    s.offer(cue(.planAndRun, "a", at: 0))
    XCTAssertEqual(s.next(at: 0, speaking: false)?.text, "a")
    s.offer(cue(.midStation, "b", at: 12))
    XCTAssertNil(s.next(at: 12, speaking: false))
    XCTAssertNil(s.next(at: 19, speaking: false))
    XCTAssertEqual(s.next(at: 20, speaking: false)?.text, "b") // 8 s old: still fresh
  }

  func testDroppingAKindRemovesOnlyThatKind() {
    var s = CueScheduler()
    s.offer(cue(.planAndRun, "a", at: 0))
    _ = s.next(at: 0, speaking: false)
    s.offer(cue(.jogIn, "Jog in.", at: 5))
    s.offer(cue(.midStation, "mid", at: 5))
    s.drop(.jogIn)
    XCTAssertEqual(s.next(at: 20, speaking: false)?.text, "mid")
    XCTAssertNil(s.next(at: 60, speaking: false))
    XCTAssertEqual(s.dropped, 0)
  }

  func testStaleCueIsDroppedAndCounted() {
    var s = CueScheduler()
    s.offer(cue(.planAndRun, "a", at: 0))
    _ = s.next(at: 0, speaking: false)
    s.offer(cue(.midStation, "b", at: 5))
    XCTAssertNil(s.next(at: 31, speaking: false)) // 26 s old
    XCTAssertEqual(s.dropped, 1)
  }

  func testACueHeldByTheGapIsNotDroppedForWaiting() {
    var s = CueScheduler()
    s.offer(cue(.wallBallSet, "set", at: 0))
    XCTAssertEqual(s.next(at: 0, speaking: false)?.text, "set")
    s.offer(cue(.planAndRun, "run", at: 5)) // offered 5 s after a cue: must wait 15 s, and still be said
    XCTAssertNil(s.next(at: 19, speaking: false))
    XCTAssertEqual(s.next(at: 20, speaking: false)?.text, "run")
    XCTAssertEqual(s.dropped, 0)
  }

  func testNeverOverlapsSpeech() {
    var s = CueScheduler()
    s.offer(cue(.stationIntro, "intro", at: 0))
    XCTAssertNil(s.next(at: 1, speaking: true))
    XCTAssertEqual(s.next(at: 2, speaking: false)?.text, "intro")
  }

  func testHigherPriorityWins() {
    var s = CueScheduler()
    s.offer(cue(.wallBallSet, "set", at: 100))
    s.offer(cue(.stationIntro, "intro", at: 100))
    XCTAssertEqual(s.next(at: 100, speaking: false)?.text, "intro")
  }

  func testFinishIgnoresTheGapAndNeverGoesStale() {
    var s = CueScheduler()
    s.offer(cue(.stationIntro, "intro", at: 100))
    _ = s.next(at: 100, speaking: false)
    s.offer(cue(.finish, "done", at: 101))
    XCTAssertNil(s.next(at: 105, speaking: true)) // still waits for speech
    XCTAssertEqual(s.next(at: 130, speaking: false)?.text, "done")
  }

  func testAtMostOneCuePerGapOverAWholeRun() {
    var s = CueScheduler()
    var spoken: [TimeInterval] = []
    for t in stride(from: 0.0, to: 120.0, by: 1.0) {
      s.offer(cue(.midStation, "m\(Int(t))", at: t))
      if s.next(at: t, speaking: false) != nil { spoken.append(t) }
    }
    XCTAssertEqual(spoken.count, 6)
    XCTAssertTrue(zip(spoken.dropFirst(), spoken).allSatisfy { $0 - $1 >= 20 })
  }
}
