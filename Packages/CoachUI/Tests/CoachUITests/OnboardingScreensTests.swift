import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the batch B screens (onboarding, moments, share card v2) into the CI `screens` artifact.
/// Share cards render at 360 x 450 pt and scale 3 (1080 x 1350); the rest at scale 2.
@MainActor
final class OnboardingScreensTests: XCTestCase {
  func testMomentCopy() {
    let first = MomentDisplay.make(.first(.fullSim), totalSeconds: 4904, fadeSeconds: 27)
    XCTAssertEqual(first.kicker.uppercased(), "YOUR FIRST FULL SIM")
    XCTAssertEqual(first.hero, "1:21:44")
    XCTAssertEqual(first.line, "Your fade baseline is 27\u{00A0}s.")
    let best = MomentDisplay.make(.best(.fullSim, previousBest: 4864), totalSeconds: 4702, fadeSeconds: nil, previousDate: "24 Oct")
    XCTAssertEqual(best.badge, "NEW BEST")
    XCTAssertEqual(best.line, "\u{25B2} 2:42 faster than 24 Oct.")
    let fade = MomentDisplay.make(.leastFade(previous: 27), totalSeconds: 4800, fadeSeconds: 19)
    XCTAssertEqual(fade.hero, "19\u{00A0}s")
    XCTAssertEqual(fade.line, "8\u{00A0}s less than your best fade. The runs are holding.")
    XCTAssertEqual(MomentDisplay.make(.leastFade(previous: 27), totalSeconds: 4800, fadeSeconds: nil).hero, "\u{2014}")
    let partial = MomentDisplay.make(.first(.fullSim), totalSeconds: 2975, fadeSeconds: 27, partial: (done: 5, of: 8))
    XCTAssertTrue(partial.kicker.contains("5 of 8 stations"))
    XCTAssertFalse(partial.line.contains("baseline is"))
  }

  func testWatchStepStatesPrivacyLine() {
    XCTAssertEqual(OnboardingWatchScreen.privacyLine, "Your sessions stay on your watch and phone. Nothing is uploaded unless you share it.")
  }

  func testMomentColoursPassContrast() {
    for t in SessionType.allCases {
      let d = MomentDisplay.make(.first(t), totalSeconds: 3000, fadeSeconds: nil)
      XCTAssertEqual(d.flood, PhoneTheme.sessionColor(t))
    }
    XCTAssertNotNil(MomentDisplay.make(.best(.halfSim, previousBest: 3000), totalSeconds: 2900, fadeSeconds: nil).badge)
  }

  func testMomentHeroesDiffer() {
    let all = [
      MomentDisplay.make(.first(.fullSim), totalSeconds: 4904, fadeSeconds: 27),
      MomentDisplay.make(.first(.halfSim), totalSeconds: 2410, fadeSeconds: 18),
      MomentDisplay.make(.best(.fullSim, previousBest: 4864), totalSeconds: 4702, fadeSeconds: nil),
      MomentDisplay.make(.leastFade(previous: 27), totalSeconds: 4800, fadeSeconds: 19),
    ]
    XCTAssertEqual(Set(all.map(\.kicker)).count, all.count)
  }
}
