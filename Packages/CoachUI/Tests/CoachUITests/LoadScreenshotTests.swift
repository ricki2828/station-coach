import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the load screens into the same `screens` folder as `ScreenshotTests`.
@MainActor
final class LoadScreenshotTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  func testRenderLoadScreens() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.loadScreens
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
    XCTAssertEqual(entries.count, 17)
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

  /// Run Supreme lesson 4: each band says something different in the hero.
  func testHeadlineDiffersPerBand() {
    let samples: [LoadSample] = [.usual, .stepUp, .bigJump, .lighter, .firstWeeks, .returning]
    let lines = samples.map { LoadWords.headline(TrainingLoad.sample($0).compare) }
    XCTAssertEqual(Set(lines).count, samples.count, "\(lines)")
    XCTAssertEqual(TrainingLoad.sample(.bigJump).compare.band, .bigJump)
  }

  func testBarsStackBySessionTypeAndFlagBigJump() {
    let d = TrainingLoad.sample(.stepUp)
    let bars = LoadBar.bars(d.weeks, calendar: d.calendar, flagCurrent: true)
    XCTAssertEqual(bars.count, 6)
    XCTAssertTrue(bars[5].flagged)
    XCTAssertFalse(bars[4].flagged)
    XCTAssertEqual(bars[5].segments.map(\.type), [.fullSim, .halfSim])
    XCTAssertEqual(bars[5].total, d.weeks[5].load, accuracy: 0.001)
  }

  func testSoFarTagOnlyOnCurrentPeriod() {
    let d = TrainingLoad.sample(.usual)
    let bars = LoadBar.bars(d.weeksSoFar, calendar: d.calendar)
    XCTAssertEqual(bars.map(\.soFar), [false, false, false, false, false, true])
    XCTAssertTrue(LoadBar.bars(d.weeks, calendar: d.calendar).allSatisfy { !$0.soFar })
  }

  func testChipOnlyAboveUsual() {
    XCTAssertEqual(WeeklySummaryScreen.chip(.bigJump), "Big jump")
    XCTAssertEqual(WeeklySummaryScreen.chip(.stepUp), "Step up")
    XCTAssertNil(WeeklySummaryScreen.chip(.usual))
    XCTAssertNil(WeeklySummaryScreen.chip(.lighter))
  }

  func testMonthUsualLineIsTheLastCompleteMonthsUsual() {
    let d = TrainingLoad.sample(.usual)
    let sessions = ScreenCatalog.demoHistory(now: d.now, calendar: d.calendar)
    let last = LoadCompare.lastComplete(sessions, unit: .month, now: d.now, calendar: d.calendar)
    XCTAssertNotNil(last.usualRounded)
    XCTAssertEqual(TrainingTotalsCard.monthUsual(sessions, now: d.now, calendar: d.calendar), last.usualRounded)
    XCTAssertTrue(TrainingTotalsCard.monthLine(last, calendar: d.calendar)?.hasPrefix("September: ") ?? false)
    // No comparison, no line and no sentence.
    let one = Array(sessions.prefix(1))
    let thin = LoadCompare.lastComplete(one, unit: .month, now: d.now, calendar: d.calendar)
    XCTAssertNil(TrainingTotalsCard.monthUsual(one, now: d.now, calendar: d.calendar))
    XCTAssertNil(TrainingTotalsCard.monthLine(thin, calendar: d.calendar))
  }

  func testScopeLabelIsOnEverySummary() {
    XCTAssertEqual(LoadWords.scopeLabel, "Station Coach sessions only")
  }
}
