import CoachKit
import SwiftUI
import UIKit
import XCTest
@testable import CoachUI

/// Measures what is drawn, not what was asked for: the dominant number is rendered in a probe colour and its
/// ink is measured in the pixels. A number shrunk by a scale factor (or squeezed out) fails here.
@MainActor
final class LayoutTests: XCTestCase {
  private let scale: CGFloat = 3

  /// Bounding box, in points, of pure-red pixels in a render of the screen inside the 46 mm chrome.
  private func probeBox(_ model: StepScreenModel) -> CGSize {
    let view = WatchChrome { CoachStepScreen(model: model, onMissed: {}) }
      .environment(\.dominantProbe, Color(red: 1, green: 0, blue: 0))
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.uiImage?.cgImage else { return .zero }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 4
        if px[i] > 235, px[i + 1] < 40, px[i + 2] < 40 {
          minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= 0 else { return .zero }
    return CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
  }

  private func model(_ kind: StepScreenModel.Kind, _ a: Activity, dominant: String, badge: String? = nil, hr: Int? = 142,
                     approximate: Bool = false) -> StepScreenModel {
    StepScreenModel(kind: kind, activity: a, title: kind == .reps ? "Wall balls" : "Run 4", badge: badge, dominant: dominant,
                    dominantLabel: "", secondary: "/ 5:24", secondaryLabel: "", next: "Next: Sled push", deltaSeconds: -20,
                    hrBpm: hr, approximate: approximate)
  }

  func testDominantDigitsAreDrawnAtFullSize() {
    let cases: [(String, StepScreenModel)] = [
      ("run", model(.run, .run, dominant: "3:12")),
      ("run, long time", model(.run, .run, dominant: "10:41")),
      ("transition", model(.run, .run, dominant: "0:12", badge: "Transition")),
      ("station", model(.time, .skierg, dominant: "2:10")),
      ("reps", model(.reps, .wallBalls, dominant: "100")),
      ("reps, approximate", model(.reps, .wallBalls, dominant: "97", approximate: true)),
    ]
    for (name, m) in cases {
      let box = probeBox(m)
      // Digit height of a 64 pt heavy face is about 0.7 em (45 pt); the 44 pt shrink the review measured gives about 31.
      XCTAssertGreaterThanOrEqual(box.height, 40, "\(name): dominant ink is \(box)")
      XCTAssertGreaterThan(box.width, 40, "\(name): dominant ink is \(box)")
    }
  }

  func testRepsNumberFitsBetweenTheButtons() {
    let box = probeBox(model(.reps, .wallBalls, dominant: "100"))
    XCTAssertGreaterThan(box.width, 0)
    XCTAssertLessThanOrEqual(box.width, Theme.watch46.width - 2 * Theme.Space.watchEdge - 88)
  }

  func testApproximateRepsKeepTheirRoomBesideTheButtons() {
    // The "~" is a badge in the title row now, so the widest count still fits with both buttons.
    for text in ["100", "97", "45"] {
      let box = probeBox(model(.reps, .wallBalls, dominant: text, approximate: true))
      XCTAssertGreaterThanOrEqual(box.height, 40, text)
      XCTAssertLessThanOrEqual(box.width, Theme.watch46.width - 2 * Theme.Space.watchEdge - 88 - 8, "\(text): \(box)")
    }
  }

  func testDominantIsTheTallestInkOnTheScreen() {
    // The delta band and secondary number must not out-shout the step's own number.
    XCTAssertGreaterThan(Theme.Size.dominant, Theme.Size.secondary)
    XCTAssertGreaterThan(Theme.Size.secondary, Theme.Size.band)
  }
}
