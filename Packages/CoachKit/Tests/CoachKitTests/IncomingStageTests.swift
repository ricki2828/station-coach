import XCTest
@testable import CoachKit

final class IncomingStageTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-stage-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func file(_ text: String) throws -> URL {
    let u = root.appendingPathComponent("src-\(UUID().uuidString)")
    try Data(text.utf8).write(to: u)
    return u
  }

  func testNameRoundTripsAwkwardNames() throws {
    let e = IncomingEntry(sid: "20261027T091500Z-ab12cd", name: "motion.csv", bytes: 123_456, total: 9)
    let n = IncomingStage.fileName(seq: 42, entry: e)
    XCTAssertFalse(n.contains("/"))
    XCTAssertLessThan(n.count, 255)
    let p = try XCTUnwrap(IncomingStage.parse(fileName: n))
    XCTAssertEqual(p.seq, 42)
    XCTAssertEqual(p.entry, e)
    XCTAssertNil(IncomingStage.parse(fileName: "not-a-staged-file"))
    XCTAssertNil(IncomingStage.parse(fileName: ".DS_Store"))
  }

  /// A zip starts, files arrive and are staged durably, the app is killed, and the next launch finds them in order with their metadata.
  func testKillMidZipThenRelaunchReappliesInOrder() throws {
    let dir = root.appendingPathComponent("stage")
    let sessions = root.appendingPathComponent("Sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let a = IncomingEntry(sid: "s1", name: "hr.csv", bytes: 5, total: 2)
    let b = IncomingEntry(sid: "s1", name: "manifest.json", bytes: 7, total: 2)
    try IncomingStage.stage(file("hello"), entry: a, seq: 1000, into: dir)
    try IncomingStage.stage(file("{\"x\":1}"), entry: b, seq: 1001, into: dir)
    // Process dies here: every in-memory queue is gone. Relaunch reads only the directory.
    let found = IncomingStage.pending(in: dir)
    XCTAssertEqual(found.map(\.entry), [a, b])
    for f in found {
      let folder = sessions.appendingPathComponent(f.entry.sid)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: f.url, to: folder.appendingPathComponent(f.entry.name))
    }
    XCTAssertEqual(try String(contentsOf: sessions.appendingPathComponent("s1/hr.csv")), "hello")
    XCTAssertTrue(IncomingStage.pending(in: dir).isEmpty)
  }

  func testPendingOrdersBySequenceNotName() throws {
    let dir = root.appendingPathComponent("stage")
    let z = IncomingEntry(sid: "z", name: "a", bytes: 1, total: 1)
    let a = IncomingEntry(sid: "a", name: "a", bytes: 1, total: 1)
    try IncomingStage.stage(file("1"), entry: z, seq: 5, into: dir)
    try IncomingStage.stage(file("2"), entry: a, seq: 9, into: dir)
    XCTAssertEqual(IncomingStage.pending(in: dir).map(\.entry.sid), ["z", "a"])
  }

  func testSweepOrphansOnlyTouchesIncomingFiles() throws {
    try Data().write(to: root.appendingPathComponent("incoming-AAA"))
    try Data().write(to: root.appendingPathComponent("incoming-BBB"))
    try Data().write(to: root.appendingPathComponent("keep.txt"))
    XCTAssertEqual(IncomingStage.sweepOrphans(inTemp: root), 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("incoming-AAA").path))
  }
}
