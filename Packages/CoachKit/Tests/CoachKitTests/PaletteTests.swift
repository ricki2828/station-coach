import XCTest
@testable import CoachKit

final class PaletteTests: XCTestCase {
  func testEveryActivityTextPasses4_5ToOne() {
    for a in Activity.allCases {
      let s = Palette.swatch(for: a)
      XCTAssertGreaterThanOrEqual(s.contrast, 4.5, "\(a.rawValue) \(String(s.hex, radix: 16))")
    }
  }

  func testStationColoursAreDistinct() {
    let hexes = Stations.race.map { Palette.swatch(for: $0).hex } + [Palette.swatch(for: .run).hex]
    XCTAssertEqual(Set(hexes).count, 9)
  }

  func testContrastMath() {
    XCTAssertEqual(Palette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    XCTAssertEqual(Palette.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
  }

  func testHeartRateZones() {
    XCTAssertEqual(Palette.zone(bpm: 100), 1)
    XCTAssertEqual(Palette.zone(bpm: 120), 2)
    XCTAssertEqual(Palette.zone(bpm: 130), 3)
    XCTAssertEqual(Palette.zone(bpm: 150), 4)
    XCTAssertEqual(Palette.zone(bpm: 175), 5)
    XCTAssertEqual(Palette.zoneHex.count, 5)
  }
}
