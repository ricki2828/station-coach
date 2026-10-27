import CoachKit
import UIKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders every watch and phone screen state to a PNG. CI uploads the folder as the `screens` artifact.
/// The watch views run in this iOS test host at the 46 mm watch point size (208 x 248): a watchOS test
/// host is not used, so system chrome (status bar, time) is not drawn and the OS-level hand gesture is not exercised.
@MainActor
final class ScreenshotTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  private func isCardName(_ n: String) -> Bool { n.contains("sharecard") }

  private func render(_ entry: CatalogEntry) throws -> Data {
    let content: AnyView
    if let size = entry.size {
      content = AnyView(entry.view.frame(width: size.width, height: size.height).clipped())
    } else {
      content = entry.view
    }
    let isCard = entry.name.contains("sharecard")
    let renderer = ImageRenderer(content: content.environment(\.colorScheme, entry.name.hasPrefix("watch-") ? .dark : .light))
    renderer.scale = isCard ? ShareCardV2.renderScale : (entry.size == nil ? 2 : 3)
    guard let image = renderer.uiImage, let png = image.pngData() else {
      throw NSError(domain: "screens", code: 1, userInfo: [NSLocalizedDescriptionKey: "no image for \(entry.name)"])
    }
    return png
  }

  func testRenderEveryScreen() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.all
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "screen names must be unique")
    XCTAssertGreaterThanOrEqual(entries.count, 50)
    for entry in entries {
      let png = try render(entry)
      XCTAssertGreaterThan(png.count, 3_000, "\(entry.name) looks blank")
      if isCardName(entry.name) {
        let image = UIImage(data: png)!
        XCTAssertEqual(image.size.width * image.scale, 1080, entry.name)
        XCTAssertEqual(image.size.height * image.scale, 1350, entry.name)
      }
      try png.write(to: outDir.appendingPathComponent("\(entry.name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = entry.name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  /// Every watch screen state at 40, 41, 42, 45 and 46 mm (the NO REP rest states included): `watch-<name>-<mm>mm.png`.
  func testRenderWatchScreensAtEveryCaseSize() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.watchSizeSweep
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "sweep names must be unique")
    XCTAssertEqual(entries.count, (ScreenCatalog.watchScreens.count + NoRepScreens.watchScreens.count) * WatchSizes.all.count)
    let base = Set(ScreenCatalog.all.map(\.name))
    for entry in entries {
      XCTAssertFalse(base.contains(entry.name), "\(entry.name) clashes with the catalog")
      let size = try XCTUnwrap(entry.size)
      XCTAssertTrue(WatchSizes.all.contains { $0.points == size }, entry.name)
      let png = try render(entry)
      XCTAssertGreaterThan(png.count, 3_000, "\(entry.name) looks blank")
      try png.write(to: outDir.appendingPathComponent("\(entry.name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = entry.name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testWatchScreensAreThe46mmSize() throws {
    for entry in ScreenCatalog.watchScreens {
      XCTAssertEqual(entry.size, Theme.watch46, entry.name)
    }
  }

  func testWatchNumbersStayAtOrAboveTheFloor() {
    XCTAssertGreaterThanOrEqual(Theme.Size.secondary, Theme.Size.floor)
    XCTAssertGreaterThanOrEqual(Theme.Size.dominant, 64)
  }
}
