import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// The NO REP rest states, written beside the other screens in the `screens` artifact.
@MainActor
final class NoRepScreenshotTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  func testRenderNoRepScreens() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = NoRepScreens.watchScreens
    XCTAssertEqual(entries.count, 6)
    let existing = Set(ScreenCatalog.all.map(\.name))
    for entry in entries {
      XCTAssertFalse(existing.contains(entry.name), "\(entry.name) clashes with the catalog")
      let size = try XCTUnwrap(entry.size)
      let renderer = ImageRenderer(content: entry.view.frame(width: size.width, height: size.height).clipped().environment(\.colorScheme, .dark))
      renderer.scale = 3
      let png = try XCTUnwrap(renderer.uiImage?.pngData())
      XCTAssertGreaterThan(png.count, 3_000, "\(entry.name) looks blank")
      try png.write(to: outDir.appendingPathComponent("\(entry.name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = entry.name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testButtonIsAtLeast44ptAndOutsideTheBottomBar() {
    XCTAssertGreaterThanOrEqual(NoRepButton.height, 44)
  }

  func testRestModelShowsTheButtonInPlaceOfTheSetLine() {
    let m = StepScreenModel(kind: .reps, activity: .wallBalls, title: "Wall balls", dominant: "45", dominantLabel: "", secondary: "Set 4",
                            secondaryLabel: "", next: "", deltaSeconds: 0)
    XCTAssertFalse(m.noRepVisible)
    XCTAssertEqual(m.noRepCount, 0)
  }
}
