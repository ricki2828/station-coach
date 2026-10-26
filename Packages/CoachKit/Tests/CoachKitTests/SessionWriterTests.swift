import XCTest
@testable import CoachKit

final class SessionWriterTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("coachkit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func manifest(_ id: String) -> SessionManifest {
    SessionManifest(sessionId: id, startedAtEpochMs: 1_000, device: "test", osVersion: "1", appVersion: "0.1", workoutActivityType: "crossTraining", motionApi: "CMBatchedSensorManager", requestedHz: 800, storeHz: 100, cueIntervalSec: 45)
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  func testManifestCarriesTheCrownNextToTheWristAndOldFilesStillDecode() throws {
    var m = manifest("s1")
    m.wrist = "left"
    m.crownOrientation = "right"
    let back = try JSONDecoder().decode(SessionManifest.self, from: JSONEncoder().encode(m))
    XCTAssertEqual(back.wrist, "left")
    XCTAssertEqual(back.crownOrientation, "right")
    let old = try JSONEncoder().encode(manifest("s2")) // no crown set: the key is simply absent
    XCTAssertNil(try JSONDecoder().decode(SessionManifest.self, from: old).crownOrientation)
  }

  func testCreatesFolderWithHeadersAndManifest() throws {
    let w = try SessionWriter(root: root, manifest: manifest("s1"))
    XCTAssertEqual(w.folder.lastPathComponent, "s1")
    for stream in SessionStream.allCases {
      let s = try text(w.folder.appendingPathComponent(stream.fileName))
      XCTAssertEqual(s, stream.header + "\n")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: w.folder.appendingPathComponent("manifest.json").path))
  }

  func testFlushPersistsAppendedLines() throws {
    let w = try SessionWriter(root: root, manifest: manifest("s2"))
    w.append(.hr, "1,100")
    w.append(.hr, "2,101")
    w.flushAll()
    XCTAssertEqual(try text(w.folder.appendingPathComponent("hr.csv")), "epoch_ms,bpm\n1,100\n2,101\n")
  }

  func testFinishWritesEndAndFileList() throws {
    let w = try SessionWriter(root: root, manifest: manifest("s3"))
    w.append(.labels, "5,set,run")
    try w.finish(endedAtEpochMs: 9_000) { $0.motionApi = "CMMotionManager" }
    let data = try Data(contentsOf: w.folder.appendingPathComponent("manifest.json"))
    let m = try JSONDecoder().decode(SessionManifest.self, from: data)
    XCTAssertEqual(m.endedAtEpochMs, 9_000)
    XCTAssertEqual(m.motionApi, "CMMotionManager")
    XCTAssertEqual(m.formatVersion, SessionFormat.version)
    XCTAssertTrue(m.files?.contains("labels.csv") ?? false)
    XCTAssertEqual(try text(w.folder.appendingPathComponent("labels.csv")), "epoch_ms,event,activity\n5,set,run\n")
  }

  func testReopeningAppendsWithoutDuplicatingHeader() throws {
    let url = root.appendingPathComponent("x.csv")
    let a = try AppendWriter(url: url, header: "h")
    a.append("1")
    a.close()
    let b = try AppendWriter(url: url, header: "h")
    b.append("2")
    b.close()
    XCTAssertEqual(try text(url), "h\n1\n2\n")
  }

  func testAppendAfterCloseIsIgnored() throws {
    let url = root.appendingPathComponent("y.csv")
    let a = try AppendWriter(url: url, header: "h")
    a.close()
    a.append("late")
    a.flush()
    XCTAssertEqual(try text(url), "h\n")
  }

  func testLargeBurstIsAllWritten() throws {
    let url = root.appendingPathComponent("z.csv")
    let a = try AppendWriter(url: url, header: "h")
    for i in 0..<20_000 { a.append("\(i),0.12345,0.12345,0.12345") }
    a.close()
    XCTAssertEqual(try text(url).split(separator: "\n").count, 20_001)
    XCTAssertEqual(a.writeErrors, 0)
  }

  func testBatchAppendKeepsOrder() throws {
    let url = root.appendingPathComponent("b.csv")
    let a = try AppendWriter(url: url, header: "h")
    a.append(lines: ["1", "2"])
    a.append(lines: [])
    a.append("3")
    a.close()
    XCTAssertEqual(try text(url), "h\n1\n2\n3\n")
  }

  func testSummariesListSessions() throws {
    let w = try SessionWriter(root: root, manifest: manifest("s4"))
    try w.finish(endedAtEpochMs: 2_000)
    let sums = SessionFiles.summaries(in: root)
    XCTAssertEqual(sums.map(\.id), ["s4"])
    XCTAssertEqual(sums.first?.fileCount, SessionStream.allCases.count + 1)
  }

  func testUnfinishedSessionIsListedAndCanBeClosed() throws {
    let w = try SessionWriter(root: root, manifest: manifest("u1"))
    w.append(.labels, "5,set,run")
    w.flushAll()
    let done = try SessionWriter(root: root, manifest: manifest("u2"))
    try done.finish(endedAtEpochMs: 3_000)
    XCTAssertEqual(SessionFiles.unfinished(in: root), ["u1"])
    try SessionFiles.closeUnfinished(in: root, id: "u1")
    XCTAssertEqual(SessionFiles.unfinished(in: root), [])
    let m = try XCTUnwrap(SessionFiles.readManifest(root.appendingPathComponent("u1")))
    XCTAssertEqual(m.recovered, true)
    XCTAssertNotNil(m.endedAtEpochMs)
    XCTAssertTrue(m.files?.contains("labels.csv") ?? false)
  }

  func testManifestKeepsLabelSource() throws {
    var m = manifest("ls")
    m.labelSource = "coach"
    m.transitionLabelSeconds = 18
    let w = try SessionWriter(root: root, manifest: m)
    try w.finish(endedAtEpochMs: 2_000)
    let back = try XCTUnwrap(SessionFiles.readManifest(w.folder))
    XCTAssertEqual(back.labelSource, "coach")
    XCTAssertEqual(back.transitionLabelSeconds, 18)
  }

  func testSessionIdFormat() {
    let id = SessionFiles.makeSessionId(date: Date(timeIntervalSince1970: 0), suffix: "abc123")
    XCTAssertEqual(id, "19700101T000000Z-abc123")
  }

  func testTransferTrackerNeedsAllFilesIntact() {
    var t = TransferTracker()
    XCTAssertFalse(t.isComplete("s"))
    t.received(session: "s", name: "a.csv", expectedBytes: 10, actualBytes: 10, total: 2)
    XCTAssertFalse(t.isComplete("s"))
    t.received(session: "s", name: "b.csv", expectedBytes: 5, actualBytes: 4, total: 2)
    XCTAssertFalse(t.isComplete("s"))
    t.received(session: "s", name: "b.csv", expectedBytes: 5, actualBytes: 5, total: 2)
    XCTAssertTrue(t.isComplete("s"))
  }

  func testTransferTrackerProgress() {
    var t = TransferTracker()
    XCTAssertNil(t.progress("s"))
    t.received(session: "s", name: "a", expectedBytes: 1, actualBytes: 1, total: 4)
    XCTAssertEqual(t.progress("s"), 25)
    t.received(session: "s", name: "b", expectedBytes: 2, actualBytes: 1, total: 4) // wrong size: not counted
    XCTAssertEqual(t.progress("s"), 25)
    t.received(session: "s", name: "b", expectedBytes: 2, actualBytes: 2, total: 4)
    XCTAssertEqual(t.progress("s"), 50)
  }

  func testTransferTrackerRoundTripsThroughJSON() throws {
    var t = TransferTracker()
    t.received(session: "s", name: "a", expectedBytes: 1, actualBytes: 1, total: 1)
    let back = try JSONDecoder().decode(TransferTracker.self, from: JSONEncoder().encode(t))
    XCTAssertEqual(back, t)
    XCTAssertTrue(back.isComplete("s"))
  }
}
