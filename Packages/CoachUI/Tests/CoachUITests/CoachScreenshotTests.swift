import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Renders the AI coach screens into the same `screens` folder as `ScreenshotTests`.
@MainActor
final class CoachScreenshotTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  func testRenderCoachScreens() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries = ScreenCatalog.coachScreens
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

  func testFactRowsAreExactlyThePayload() {
    let facts = CoachFactRow.exampleFacts
    let ids = CoachFactRow.rows(for: facts).map(\.id)
    XCTAssertEqual(Array(ids.prefix(7)), ["installId", "date", "sessionType", "division", "target", "total", "steps"])
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  func testReconsentSampleShowsAChangedRow() {
    XCTAssertFalse(CoachFactRow.rows(for: CoachFactRow.exampleFacts).filter { $0.id == "reference" }.isEmpty)
  }

  func testNeverSentListNamesWhatTheFactsLeaveOut() {
    let never = CoachConsentCopy.neverSent.joined(separator: "|").lowercased()
    for word in ["heart rate", "motion", "location", "name", "health", "age or weight", "notes"] {
      XCTAssertTrue(never.contains(word), word)
    }
  }

  func testProviderSentenceFollowsTheRetentionAnswer() {
    let kept = CoachConsentCopy.whoSees(zeroRetentionConfirmed: false)
    XCTAssertTrue(kept.contains("may keep them for up to 30 days"))
    XCTAssertTrue(kept.contains("OpenRouter") && kept.contains("Anthropic"), "both parties that receive the facts are named")
    let zdr = CoachConsentCopy.whoSees(zeroRetentionConfirmed: true)
    XCTAssertTrue(zdr.contains("Neither keeps them") && zdr.contains("OpenRouter") && zdr.contains("Anthropic"))
  }

  func testCopyHasNoRaceBrandTerm() {
    let all = ([CoachConsentCopy.offerBody, CoachConsentCopy.howLong, CoachConsentCopy.debriefError] + CoachConsentCopy.neverSent).joined().lowercased()
    XCTAssertFalse(all.contains("hy" + "rox"))
  }

  func testDebriefDisplayMapsEveryState() {
    XCTAssertNil(DebriefDisplay(.none))
    XCTAssertEqual(DebriefDisplay(.queued), .queued)
    XCTAssertEqual(DebriefDisplay(.reply("x")), .reply("x"))
    XCTAssertEqual(DebriefDisplay(.error), .error)
    XCTAssertEqual(DebriefDisplay(.cap), .cap)
  }

  func testDayShort() {
    XCTAssertEqual(CoachDay.short("2026-10-27"), "27 Oct")
    XCTAssertEqual(CoachDay.short("nonsense"), "nonsense")
  }
}
