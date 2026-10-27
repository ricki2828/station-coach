import XCTest
@testable import CoachKit

/// Encodes REAL CoachKit structs and compares them with tools/fixtures/swift-contract/*.json, which
/// tools/tests/test_schema.py validates against docs/schema/*.schema.json. A new Codable field changes the encoding,
/// fails here until the fixture is regenerated, and then fails the schema test until the schema is updated.
/// Regenerate: SC_UPDATE_CONTRACT=1 swift test --filter SchemaContractTests (run from Packages/CoachKit).
/// Optionals are all set in the "full" variants and all nil in the "min" ones, so a new optional field shows up too.
final class SchemaContractTests: XCTestCase {
  private var dir: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tools/fixtures/swift-contract")
  }

  private func check<T: Encodable>(_ value: T, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let url = dir.appendingPathComponent("\(name).json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(value)
    if ProcessInfo.processInfo.environment["SC_UPDATE_CONTRACT"] == "1" {
      try (data + Data("\n".utf8)).write(to: url)
      return
    }
    let committed = try Data(contentsOf: url)
    let got = try JSONSerialization.jsonObject(with: data) as AnyObject
    let want = try JSONSerialization.jsonObject(with: committed) as AnyObject
    XCTAssertTrue(got.isEqual(want), "\(name).json is out of date with the Swift type. Encoded now:\n\(String(decoding: data, as: UTF8.self))", file: file, line: line)
  }

  private var plan: SessionPlan {
    SessionPlan(division: .openMen, type: .wallBallFocus, raceTargetSeconds: 5400, steps: [
      PlanStep(activity: .run, index: 0, runNumber: 1, targetSeconds: 300, reps: nil, sets: []),
      PlanStep(activity: .wallBalls, index: 1, runNumber: nil, targetSeconds: 240, reps: 50, sets: [25, 25]),
    ], transitionSeconds: 10)
  }

  func testPlan() throws {
    try check(plan, "plan")
  }

  func testManifestFullAndMin() throws {
    var full = SessionManifest(
      sessionId: "20261027T090000Z-abc123", startedAtEpochMs: 1_790_000_000_000, device: "Watch7,1", osVersion: "watchOS 11.0",
      appVersion: "0.1.0", workoutActivityType: "crossTraining", motionApi: "CMBatchedSensorManager", requestedHz: 800, storeHz: 100,
      cueIntervalSec: 0, audioMode: AudioMode.longForm.rawValue, athlete: "A1", wrist: "left", crownOrientation: "right",
      labelSource: "coach", transitionLabelSeconds: 10)
    full.endedAtEpochMs = 1_790_005_400_000
    full.files = ["manifest.json", "coach.json"]
    full.recovered = true
    full.resumed = 2
    try check(full, "manifest-full")
    let min = SessionManifest(
      sessionId: "s", startedAtEpochMs: 1, device: "d", osVersion: "o", appVersion: "a", workoutActivityType: "w",
      motionApi: "CMMotionManager", requestedHz: 100, storeHz: 50, cueIntervalSec: 45)
    try check(min, "manifest-min")
  }

  func testCoachFullAndMin() throws {
    let splits = [StepSplit(stepIndex: 0, startMs: 1_790_000_000_000, endMs: 1_790_000_300_000),
                  StepSplit(stepIndex: 1, startMs: 1_790_000_300_000)]
    let full = CoachResult(
      plan: plan, splits: splits, early: true, repTimesMs: [1_790_000_310_000, 1_790_000_313_000], repCorrection: -1,
      startedAtEpochMs: 1_790_000_000_000, endedAtEpochMs: 1_790_000_400_000,
      noReps: [NoRepEvent(tMs: 1_790_000_313_500, setIndex: 0, stepIndex: 1)],
      wallBallCorrection: WallBallCorrection(validReps: 48, noReps: 2))
    try check(full, "coach-full")
    let min = CoachResult(plan: plan, splits: [], early: false, repTimesMs: [], repCorrection: 0, startedAtEpochMs: 1, endedAtEpochMs: 2)
    try check(min, "coach-min")
  }

  func testPhoneCorrection() throws {
    try check(WallBallCorrection(validReps: 48, noReps: 2), "phone-correction")
  }

  /// Early builds wrote a bare Int (total throws) for `wallBallCorrection`: it decodes, and the schema accepts it.
  func testLegacyBareIntCorrectionDecodes() throws {
    let data = try Data(contentsOf: dir.appendingPathComponent("coach-legacy-int.json"))
    let r = try JSONDecoder().decode(CoachResult.self, from: data)
    XCTAssertEqual(r.noReps.count, 2)
    XCTAssertEqual(r.wallBallCorrection, WallBallCorrection(validReps: 18, noReps: 2)) // 20 throws - 2 no-reps
  }
}
