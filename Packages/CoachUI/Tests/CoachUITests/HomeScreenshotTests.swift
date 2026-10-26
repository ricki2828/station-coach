import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the Home, History and detail screens into the same `screens` folder as `ScreenshotTests`.
@MainActor
final class HomeScreenshotTests: XCTestCase {
  func testHomeHeroCopyDiffersPerState() {
    let states = ScreenCatalog.homeStates.filter { $0.name != "next-wallballs" }
    let sigs = states.map { s in [s.model.kicker, s.model.hero, s.model.chip ?? "-"].joined(separator: "|") }
    XCTAssertEqual(Set(sigs).count, states.count, "each Home state needs its own hero: \(sigs)")
    XCTAssertEqual(states.map(\.model.state), [.none, .baseline, .trend(.down), .trend(.steady), .trend(.up)])
  }

  func testWallBallSampleRecommendsWallBallFocus() {
    let m = ScreenCatalog.homeStates.first { $0.name == "next-wallballs" }!.model
    XCTAssertEqual(m.next.type, .wallBallFocus)
  }

  func testSamplesHitTheirFade() {
    XCTAssertEqual(HistorySamples.baseline[0].fade, 27)
    XCTAssertEqual(HistorySamples.list[0].fade, 19)
    XCTAssertNotNil(HistorySamples.list[3].fade)
    XCTAssertFalse(HistorySamples.list[3].isComplete)
  }

  func testEditCountPrefillsFromResult() {
    let r = HistorySamples.withNoReps(HistorySamples.list[0], count: 3)
    XCTAssertEqual(WallBallCountAdapter.initial(for: r), WallBallEdit(validReps: r.result.validReps, noReps: 3))
    var corrected = r.result
    corrected.wallBallCorrection = WallBallCorrection(validReps: 96, noReps: 4)
    XCTAssertEqual(WallBallCountAdapter.initial(for: SessionRecord(id: r.id, result: corrected)), WallBallEdit(validReps: 96, noReps: 4))
  }
}
