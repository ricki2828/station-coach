import CoachKit
import SwiftUI
import UIKit
import XCTest
@testable import CoachUI

private final class SizeBox: @unchecked Sendable { var size = CGSize.zero }

/// Measures what is laid out, not what was asked for: a shrunk or truncated dominant number fails here.
@MainActor
final class LayoutTests: XCTestCase {
  private func dominantSize(_ model: StepScreenModel) -> CGSize {
    let box = SizeBox()
    let root = CoachStepScreen(model: model, onMissed: {})
      .frame(width: Theme.watch46.width, height: Theme.watch46.height)
      .onPreferenceChange(DominantSizeKey.self) { box.size = $0 }
    let host = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(origin: .zero, size: Theme.watch46))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    return box.size
  }

  private func model(_ kind: StepScreenModel.Kind, _ a: Activity, dominant: String, badge: String? = nil, hr: Int? = 142) -> StepScreenModel {
    StepScreenModel(kind: kind, activity: a, title: "Run 4", badge: badge, dominant: dominant, dominantLabel: "", secondary: "/ 5:24",
                    secondaryLabel: "", next: "Next: Sled push", deltaSeconds: -20, hrBpm: hr)
  }

  func testDominantNumberIsLaidOutAtFullSize() {
    let cases: [(String, StepScreenModel)] = [
      ("run", model(.run, .run, dominant: "3:12")),
      ("run with hr", model(.run, .run, dominant: "10:41")),
      ("transition", model(.run, .run, dominant: "0:12", badge: "Transition")),
      ("station", model(.time, .skierg, dominant: "2:10")),
      ("reps", model(.reps, .wallBalls, dominant: "100")),
      ("reps approx", model(.reps, .wallBalls, dominant: "~97")),
    ]
    for (name, m) in cases {
      let size = dominantSize(m)
      // A 64 pt condensed heavy line is about 75 pt tall; a 44 pt shrink is about 52.
      XCTAssertGreaterThanOrEqual(size.height, 64 * 0.9, "\(name): dominant laid out at \(size)")
      XCTAssertGreaterThan(size.width, 30, "\(name): dominant laid out at \(size)")
    }
  }

  func testRepsDominantFitsBetweenTheButtons() {
    let size = dominantSize(model(.reps, .wallBalls, dominant: "100"))
    XCTAssertLessThanOrEqual(size.width, Theme.watch46.width - 2 * Theme.Space.watchEdge - 88)
  }
}
