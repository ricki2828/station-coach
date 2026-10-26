import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the batch B screens (onboarding, moments, share card v2) into the CI `screens` artifact.
/// Share cards render at 360 x 450 pt and scale 3 (1080 x 1350); the rest at scale 2.
@MainActor
final class OnboardingScreensTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  func testRenderBatchBScreens() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.onboardingScreens
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
    for entry in entries {
      let isCard = entry.name.contains("sharecard")
      let renderer = ImageRenderer(content: entry.view.environment(\.colorScheme, .light))
      renderer.scale = isCard ? ShareCardV2.renderScale : 2
      guard let image = renderer.uiImage, let png = image.pngData() else { return XCTFail("no image for \(entry.name)") }
      XCTAssertGreaterThan(png.count, 5_000, "\(entry.name) looks blank")
      if isCard {
        XCTAssertEqual(image.size.width * image.scale, 1080, entry.name)
        XCTAssertEqual(image.size.height * image.scale, 1350, entry.name)
      }
      try png.write(to: outDir.appendingPathComponent("\(entry.name).png"))
      let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      a.name = entry.name
      a.lifetime = .keepAlways
      add(a)
    }
  }

  func testMomentCopy() {
    let first = MomentDisplay.make(.first(.fullSim), totalSeconds: 4904, fadeSeconds: 27)
    XCTAssertEqual(first.kicker.uppercased(), "YOUR FIRST FULL SIM")
    XCTAssertEqual(first.hero, "1:21:44")
    XCTAssertEqual(first.line, "Your fade baseline is 27\u{00A0}s.")
    let best = MomentDisplay.make(.best(.fullSim, previousBest: 4864), totalSeconds: 4702, fadeSeconds: nil, previousDate: "24 Oct")
    XCTAssertEqual(best.kicker.uppercased(), "NEW FULL SIM BEST")
    XCTAssertEqual(best.line, "2:42 faster than 24 Oct.")
    let fade = MomentDisplay.make(.leastFade(previous: 27), totalSeconds: 4800, fadeSeconds: 19)
    XCTAssertEqual(fade.hero, "19\u{00A0}s")
  }

  func testMomentColoursPassContrast() {
    for t in SessionType.allCases {
      let d = MomentDisplay.make(.first(t), totalSeconds: 3000, fadeSeconds: nil)
      XCTAssertEqual(d.flood, PhoneTheme.sessionColor(t))
    }
    XCTAssertEqual(MomentDisplay.make(.best(.halfSim, previousBest: 3000), totalSeconds: 2900, fadeSeconds: nil).flood, PhoneTheme.best)
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
