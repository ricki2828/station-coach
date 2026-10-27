import XCTest
@testable import CoachKit

/// Shares tools/fixtures/wallball/ with tools/tests/test_wallball_replay.py, which asserts the same
/// expected.json against the Python port. The signals are synthetic (see generate.py), not recordings.
/// If this fails, either WallBallCounter.swift or tools/wallball_replay.py changed without the other.
final class WallBallGoldenTests: XCTestCase {
  private var dir: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tools/fixtures/wallball")
  }

  private func samples(_ name: String) throws -> [(Double, Double)] {
    let text = try String(contentsOf: dir.appendingPathComponent("\(name).csv"), encoding: .utf8)
    return try text.split(separator: "\n").dropFirst().map { line in
      let f = line.split(separator: ",")
      guard f.count == 2, let t = Double(f[0]), let m = Double(f[1]) else { throw CocoaError(.fileReadCorruptFile) }
      return (t, m)
    }
  }

  func testGoldenFixturesMatchExpected() throws {
    let data = try Data(contentsOf: dir.appendingPathComponent("expected.json"))
    let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    XCTAssertGreaterThanOrEqual(expected.count, 15)
    for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
      var c = WallBallCounter()
      for (t, m) in try samples(name) { c.add(t: t, magnitude: m) }
      XCTAssertEqual(c.count, want["count"] as? Int, name)
      let conf = c.confidence == .high ? "high" : "low"
      XCTAssertEqual(conf, want["confidence"] as? String, name)
      let times = (want["repTimes"] as? [Double]) ?? []
      XCTAssertEqual(c.repTimes.count, times.count, name)
      for (got, exp) in zip(c.repTimes, times) { XCTAssertEqual(got, exp, accuracy: 0.005, name) }
    }
  }
}
