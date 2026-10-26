import CoachKit
import SwiftUI
import XCTest
@testable import CoachUI

/// Contrast checks for the phone tokens, and the `phone-tokens-sheet` gallery PNG that CI uploads with the other screens.
@MainActor
final class PhoneThemeTests: XCTestCase {
  func testSessionColoursPassContrast() {
    for t in SessionType.allCases {
      let c = Palette.contrast(PhoneTheme.sessionHex(t), PhoneTheme.sessionTextHex(t))
      XCTAssertGreaterThanOrEqual(c, 4.5, t.title)
    }
    XCTAssertGreaterThanOrEqual(Palette.contrast(PhoneTheme.bestHex, Palette.ink), 4.5)
  }

  func testTextOnPaperPassesContrast() {
    XCTAssertGreaterThanOrEqual(Palette.contrast(PhoneTheme.mutedHex, PhoneTheme.paperHex), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(PhoneTheme.amberTextHex, PhoneTheme.paperHex), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, PhoneTheme.paperHex), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(PhoneTheme.mutedHex, PhoneTheme.cardHex), 4.5)
  }

  func testWhySheetZoneChipsPassContrast() {
    for (i, hex) in Palette.zoneHex.enumerated() {
      XCTAssertGreaterThanOrEqual(Palette.contrast(hex, Palette.ink), 4.5, "zone \(i + 1)")
    }
    // Chip on the violet hero: amber text on the paper-coloured pill.
    XCTAssertGreaterThanOrEqual(Palette.contrast(PhoneTheme.amberTextHex, PhoneTheme.paperHex), 4.5)
  }

  func testSessionColoursAreDistinct() {
    XCTAssertEqual(Set(SessionType.allCases.map { PhoneTheme.sessionHex($0) }).count, SessionType.allCases.count)
  }

  func testWordmarkBarHasNineSegments() {
    XCTAssertEqual(Wordmark.barActivities.count, 9)
  }

  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).phoneKicker()
      content()
    }
  }

  private var sheet: some View {
    let full = SampleData.result(extra: [1: -25, 5: 41, 9: 30])
    let partial = SampleData.result(until: 10)
    let colors = [0, 1, 2, 3, 4, 5].map { Theme.color(Palette.swatch(for: Wordmark.barActivities[($0 % 8) + 1]).hex) }
    return VStack(alignment: .leading, spacing: 28) {
      section("Wordmark") {
        Wordmark(size: 22)
        Wordmark(size: 44)
      }
      section("Session chips") {
        HStack(spacing: 6) { ForEach(SessionType.allCases) { SessionChip($0) } }
      }
      section("Hero cards") {
        ForEach(SessionType.allCases) { t in
          HeroCard(type: t) {
            VStack(alignment: .leading, spacing: 6) {
              Text(t.title).phoneKicker(color: PhoneTheme.sessionText(t))
              Text("1:21:44").phoneHero()
              Text("1:44 over target").font(.system(size: 17, weight: .semibold))
            }
          }
        }
        HeroCard(color: PhoneTheme.best, textColor: PhoneTheme.bestText) {
          VStack(alignment: .leading, spacing: 6) {
            Text("New best").phoneKicker(color: PhoneTheme.bestText)
            Text("1:19:02").phoneHero()
          }
        }
      }
      section("Statement and cards") {
        Text("Find your fade").phoneStatement()
        StatTile(kicker: "Total", value: "1:21:44", caption: "1:44 over target")
        PhoneCard {
          HStack {
            Text("45 s over").font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.amberText)
            Spacer()
            Text("on plan").font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
          }
        }
        HStack(spacing: 8) {
          ForEach([Activity.skierg, .sledPush, .row, .wallBalls], id: \.self) { a in
            Text(Stations.name(a)).font(.system(size: 13, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(PhoneTheme.stationTint(a), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      section("Station strip, full (labelled) and partial") {
        StationStrip(result: full, labelled: true, height: 14)
        StationStrip(result: partial, labelled: false, height: 8)
      }
      section("Recent bars") {
        RecentBars(values: [27, 31, 24, 22, 19, 19], colors: colors, caption: "Lower is better")
      }
      section("Buttons") {
        PrimaryButton("Continue") {}
        SecondaryButton("Nice") {}
        TextLinkButton("Export data") {}
      }
    }
    .padding(24)
    .frame(width: Theme.phone.width, alignment: .leading)
    .background(PhoneTheme.paper)
  }

  func testRenderPhoneTokensSheet() throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, .light))
    renderer.scale = 2
    guard let png = renderer.uiImage?.pngData() else { return XCTFail("no image") }
    XCTAssertGreaterThan(png.count, 10_000)
    try png.write(to: outDir.appendingPathComponent("phone-tokens-sheet.png"))
    let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    a.name = "phone-tokens-sheet"
    a.lifetime = .keepAlways
    add(a)
  }
}
