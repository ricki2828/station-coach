import XCTest
@testable import CoachKit

final class CueHapticTests: XCTestCase {
  private let allKinds: [CoachCueKind] = [.jogIn, .wallBallSet, .midStation, .planAndRun, .stationIntro, .finish, .noRep]

  func testFiveDistinctKinds() {
    XCTAssertEqual(Set(allKinds.map(CueHaptic.for)).count, 5)
    XCTAssertEqual(HapticKind.allCases.count, 5)
  }

  func testEveryHapticHasItsOwnPattern() {
    XCTAssertEqual(Set(HapticKind.allCases.map(\.signature)).count, 5)
  }

  func testFinishIsUnique() {
    let finish = allKinds.filter { CueHaptic.for($0) == .finish }
    XCTAssertEqual(finish, [.finish])
    for kind in HapticKind.allCases where kind != .finish {
      XCTAssertNotEqual(kind.motion, HapticKind.finish.motion)
      XCTAssertLessThan(kind.pulses, HapticKind.finish.pulses)
    }
  }

  func testNamedCuesMapToTheirOwnKind() {
    XCTAssertEqual(CueHaptic.for(.stationIntro), .stationIntro)
    XCTAssertEqual(CueHaptic.for(.wallBallSet), .setDone)
    XCTAssertEqual(CueHaptic.for(.jogIn), .jogIn)
    XCTAssertEqual(CueHaptic.for(.planAndRun), .planBehind)
  }
}
