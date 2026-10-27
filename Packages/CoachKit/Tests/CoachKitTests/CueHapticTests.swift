import XCTest
@testable import CoachKit

final class CueHapticTests: XCTestCase {
  private let allKinds: [CoachCueKind] = [.jogIn, .wallBallSet, .midStation, .planAndRun, .stationIntro, .finish, .noRep]

  func testEveryHapticHasItsOwnPattern() {
    XCTAssertEqual(HapticKind.allCases.count, 6)
    XCTAssertEqual(Set(HapticKind.allCases.map(\.signature)).count, 6)
  }

  func testFinishIsUnique() {
    for delta in [-60, 0, 60] {
      let finish = allKinds.filter { CueHaptic.for($0, deltaSeconds: delta) == .finish }
      XCTAssertEqual(finish, [.finish])
    }
    for kind in HapticKind.allCases where kind != .finish {
      XCTAssertNotEqual(kind.motion, HapticKind.finish.motion)
      XCTAssertLessThan(kind.pulses, HapticKind.finish.pulses)
    }
  }

  func testNamedCuesMapToTheirOwnKind() {
    XCTAssertEqual(CueHaptic.for(.stationIntro, deltaSeconds: 0), .stationIntro)
    XCTAssertEqual(CueHaptic.for(.wallBallSet, deltaSeconds: 0), .setDone)
    XCTAssertEqual(CueHaptic.for(.jogIn, deltaSeconds: 0), .jogIn)
  }

  func testPlanCueFollowsTheSignOfTheDelta() {
    for kind in [CoachCueKind.midStation, .planAndRun] {
      XCTAssertEqual(CueHaptic.for(kind, deltaSeconds: 30), .planBehind, "behind: falling")
      XCTAssertEqual(CueHaptic.for(kind, deltaSeconds: -30), .planAhead, "ahead must not feel like behind")
      XCTAssertEqual(CueHaptic.for(kind, deltaSeconds: 4), .setDone, "inside 10 s is on plan")
      XCTAssertEqual(CueHaptic.for(kind, deltaSeconds: -9), .setDone)
      XCTAssertNotEqual(HapticKind.planAhead.motion, HapticKind.jogIn.motion, "ahead must not be a jog-in with a different count")
    }
  }
}
