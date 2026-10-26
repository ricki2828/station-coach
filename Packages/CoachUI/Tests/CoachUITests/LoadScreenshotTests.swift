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
    let entries = ScreenCatalog.loadScreens + ScreenCatalog.loadWiredScreens
    XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
    XCTAssertEqual(entries.count, 23)
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

  func testHomeCardNoteIsTheWeekInProgressNotTheLastCompleteWeek() {
    // Two complete weeks of history, one session this week: this week is "so far" and the card says nothing about thresholds
    // once a usual exists.
    let d = TrainingLoad.sample(.usual)
    let m = WeekCardModel.make(d.sessions, now: d.now, calendar: d.calendar)
    XCTAssertNotNil(m)
    XCTAssertTrue(m!.period.isCurrent)
    XCTAssertNil(m!.note)
    // A first-weeks athlete on the Tuesday of week 2: the note follows this week's state, not the last complete week's.
    let f = TrainingLoad.sample(.firstWeeks)
    let tue = f.weekStart.addingTimeInterval(86_400 + 12 * 3_600)
    let early = f.sessions.filter { $0.date < tue }
    let fm = WeekCardModel.make(early, now: tue, calendar: f.calendar)
    XCTAssertEqual(LoadCompare.current(early, now: tue, calendar: f.calendar).state, .firstWeeks)
    XCTAssertEqual(fm?.note, "Your usual week takes shape after 3 sessions across 2 weeks.")
    XCTAssertNil(WeekCardModel.make([], now: d.now, calendar: d.calendar))
  }

  func testBestFadeIsTheMonthsLowestCompleteFade() {
    let now = HistorySamples.today
    let cal = TrainingLoad.sampleCalendar
    // list: fades 19, 14, 12 complete, 31 partial; all in October.
    XCTAssertEqual(TrainingTotalsCard.bestFade(HistorySamples.list, now: now, calendar: cal), 12)
    XCTAssertNil(TrainingTotalsCard.bestFade([], now: now, calendar: cal))
  }

  func testRealRecordsMakeLoadSessions() {
    let sessions = ScreenCatalog.loadSessions(HistorySamples.list)
    XCTAssertEqual(sessions.count, 4)
    XCTAssertTrue(sessions.allSatisfy { $0.load.load > 0 })
  }

  func testScopeLabelIsOnEverySummary() {
    XCTAssertEqual(LoadWords.scopeLabel, "Station Coach sessions only")
  }
}
