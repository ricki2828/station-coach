import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the Home, History and detail screens into the same `screens` folder as `ScreenshotTests`.
@MainActor
final class HomeScreenshotTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  func testRenderHomeAndHistoryScreens() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.homeScreens
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
    for entry in entries {
      let renderer = ImageRenderer(content: entry.view.environment(\.colorScheme, .light))
      renderer.scale = 2
      guard let png = renderer.uiImage?.pngData() else { return XCTFail("no image for \(entry.name)") }
      XCTAssertGreaterThan(png.count, 3_000, "\(entry.name) looks blank")
      try png.write(to: outDir.appendingPathComponent("\(entry.name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = entry.name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

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
}
