import XCTest
@testable import CoachKit

private final class FakeTransport: CoachTransport {
  var requests: [CoachHTTPRequest] = []
  var handler: (CoachHTTPRequest) throws -> CoachHTTPResponse

  init(_ handler: @escaping (CoachHTTPRequest) throws -> CoachHTTPResponse) { self.handler = handler }

  func send(_ request: CoachHTTPRequest) async throws -> CoachHTTPResponse {
    requests.append(request)
    return try handler(request)
  }

  static func ok() -> FakeTransport {
    FakeTransport { r in
      switch r.path {
      case "/v1/register": return CoachHTTPResponse(status: 200, body: Data(#"{"deviceToken":"tok"}"#.utf8))
      case "/v1/coach": return CoachHTTPResponse(status: 200, body: Data(#"{"reply":"Sled push took 4:20.","kind":"debrief","remainingToday":2}"#.utf8))
      default: return CoachHTTPResponse(status: 200, body: Data(#"{"deletedSessions":2}"#.utf8))
      }
    }
  }
}

private struct Offline: Error {}

final class CoachServiceTests: XCTestCase {
  private let on = CoachConfig(enabled: true, baseURL: "https://coach.invalid")

  private func result() -> CoachResult {
    let plan = PlanBuilder.build(division: .openMen, target: 4800, type: .halfSim)
    var t: Int64 = 0
    let splits = plan.steps.map { s -> StepSplit in
      defer { t += Int64(s.targetSeconds) * 1000 }
      return StepSplit(stepIndex: s.index, startMs: t, endMs: t + Int64(s.targetSeconds) * 1000)
    }
    return CoachResult(plan: plan, splits: splits, early: false, repTimesMs: [], repCorrection: 0, startedAtEpochMs: 0, endedAtEpochMs: t)
  }

  func testDefaultConfigIsOffAndEmpty() {
    XCTAssertFalse(CoachConfig().enabled)
    XCTAssertEqual(CoachConfig().baseURL, "")
    XCTAssertFalse(CoachConfig().isAvailable)
    XCTAssertFalse(CoachConfig(enabled: true).isAvailable, "a flag without a base URL still sends nothing")
    XCTAssertFalse(CoachConfig(enabled: false, baseURL: "https://x.invalid").isAvailable)
  }

  func testFlagOffMakesNoRequestAndWritesNothing() async {
    let net = FakeTransport.ok()
    let store = MemoryCoachStore()
    for cfg in [CoachConfig(), CoachConfig(enabled: true), CoachConfig(enabled: false, baseURL: "https://x.invalid")] {
      let svc = CoachService(config: cfg, transport: net, store: store)
      let turned = await svc.turnOn()
      XCTAssertEqual(turned, .unavailable)
      _ = await svc.submit(sessionId: "s1", result: result())
      await svc.flush()
      _ = await svc.turnOff()
      _ = await svc.retryPendingDelete()
      XCTAssertEqual(svc.state, .off)
    }
    XCTAssertEqual(net.requests.count, 0)
    XCTAssertEqual(store.keys, [])
  }

  func testNoRequestWithoutConsentEvenWhenTheFlagIsOn() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    let state = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(state, .none)
    XCTAssertEqual(net.requests.count, 0)
    XCTAssertEqual(svc.queuedCount, 0)
  }

  func testConsentIsRecordedOnlyAfterTheServiceConfirms() async {
    let down = FakeTransport { _ in throw Offline() }
    let svc = CoachService(config: on, transport: down, store: MemoryCoachStore())
    let r = await svc.turnOn()
    XCTAssertEqual(r, .failed)
    XCTAssertEqual(svc.state, .off)

    let rejected = FakeTransport { _ in CoachHTTPResponse(status: 403) }
    let svc2 = CoachService(config: on, transport: rejected, store: MemoryCoachStore())
    let r2 = await svc2.turnOn()
    XCTAssertEqual(r2, .failed)
    XCTAssertEqual(svc2.state, .off)
  }

  func testTurnOnThenSubmitSendsFactsWithTheTokenAndStoresTheReply() async throws {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    let turned = await svc.turnOn()
    XCTAssertEqual(turned, .on)
    guard case .on = svc.state else { return XCTFail("not on") }
    let state = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(state, .reply("Sled push took 4:20."))
    let sent = net.requests.last!
    XCTAssertEqual(sent.path, "/v1/coach")
    XCTAssertEqual(sent.bearer, "tok")
    let body = try JSONSerialization.jsonObject(with: sent.body!) as! [String: Any]
    XCTAssertTrue(Set(body.keys).isSubset(of: CoachFacts.allowedKeys))
    XCTAssertEqual(body["consentVersion"] as? Int, CoachConsent.currentVersion)
    XCTAssertEqual(svc.queuedCount, 0)
  }

  func testOfflineQueuesThenSendsOnNextFlush() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    let queued = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(queued, .queued)
    XCTAssertEqual(svc.queuedCount, 1)
    net.handler = FakeTransport.ok().handler
    await svc.flush()
    XCTAssertEqual(svc.debriefState(for: "s1"), .reply("Sled push took 4:20."))
    XCTAssertEqual(svc.queuedCount, 0)
  }

  func testRevokingConsentClearsTheQueueAndRepliesAndDeletesRemotely() async {
    let net = FakeTransport.ok()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(svc.queuedCount, 1)
    net.handler = FakeTransport.ok().handler
    let out = await svc.turnOff()
    XCTAssertEqual(out, .deleted(2))
    XCTAssertEqual(svc.queuedCount, 0)
    XCTAssertEqual(svc.state, .off)
    XCTAssertEqual(svc.debriefState(for: "s1"), .none)
    XCTAssertEqual(net.requests.last?.method, "DELETE")
    XCTAssertEqual(store.keys, [], "nothing is left on the phone")
    // after revoking, a new session sends nothing
    let before = net.requests.count
    _ = await svc.submit(sessionId: "s2", result: result())
    XCTAssertEqual(net.requests.count, before)
  }

  func testRevokingWhileOfflineClearsLocallyAndRetriesTheDelete() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    let out = await svc.turnOff()
    XCTAssertEqual(out, .pending)
    XCTAssertEqual(svc.state, .off)
    XCTAssertEqual(svc.queuedCount, 0)
    XCTAssertTrue(svc.hasPendingDelete)
    net.handler = FakeTransport.ok().handler
    let retried = await svc.retryPendingDelete()
    XCTAssertEqual(retried, .deleted(2))
    XCTAssertFalse(svc.hasPendingDelete)
  }

  func testChangedConsentVersionSendsNothingUntilAnswered() async throws {
    let net = FakeTransport.ok()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    // an older consent on disk, as after an app update that bumps the consent version
    var rec = try JSONDecoder().decode(CoachConsentRecord.self, from: store.data(forKey: "coach.consent")!)
    rec.version = CoachConsent.currentVersion - 1
    store.set(try JSONEncoder().encode(rec), forKey: "coach.consent")
    XCTAssertEqual(svc.state, .needsReconsent)
    let before = net.requests.count
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(net.requests.count, before)
    let kept = await svc.acceptReconsent()
    XCTAssertEqual(kept, .on)
    guard case .on = svc.state else { return XCTFail("not on") }
  }

  func testDailyCapShowsCapStateAndIsNotRetried() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in CoachHTTPResponse(status: 429, body: Data(#"{"error":"daily_cap"}"#.utf8)) }
    let s = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(s, .cap)
    XCTAssertEqual(svc.queuedCount, 0)
  }

  func testRepeatedServerErrorsEndInTheErrorState() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in CoachHTTPResponse(status: 502, body: Data(#"{"error":"reply_rejected"}"#.utf8)) }
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(svc.debriefState(for: "s1"), .queued)
    await svc.flush()
    await svc.flush()
    XCTAssertEqual(svc.debriefState(for: "s1"), .error)
  }

  func testServerForgettingTheInstallReturnsToOff() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in CoachHTTPResponse(status: 401) }
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(svc.state, .off)
    XCTAssertEqual(svc.queuedCount, 0)
  }
}
