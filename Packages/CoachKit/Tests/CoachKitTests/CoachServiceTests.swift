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

/// Suspends the first debrief POST until the test lets it go, so a turn-off can run while a send is in flight.
private final class GatedTransport: CoachTransport {
  var offline = false
  var posts = 0
  var gate: CheckedContinuation<Void, Never>?
  var gateFirstPost = false
  var gateNextRegister = false
  var registers = 0

  func send(_ r: CoachHTTPRequest) async throws -> CoachHTTPResponse {
    if offline { throw Offline() }
    switch r.path {
    case "/v1/register":
      registers += 1
      if gateNextRegister {
        gateNextRegister = false
        await withCheckedContinuation { gate = $0 }
      }
      return CoachHTTPResponse(status: 200, body: Data(#"{"deviceToken":"tok\#(registers)"}"#.utf8))
    case "/v1/coach":
      posts += 1
      if gateFirstPost && posts == 1 { await withCheckedContinuation { gate = $0 } }
      return CoachHTTPResponse(status: 200, body: Data(#"{"reply":"A debrief.","kind":"debrief","remainingToday":1}"#.utf8))
    default: return CoachHTTPResponse(status: 200, body: Data(#"{"deletedSessions":2}"#.utf8))
    }
  }
}

@MainActor
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

  func testTurnOffWhileASendIsInFlightStopsTheQueueAndWritesNoReply() async {
    let net = GatedTransport()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    net.offline = true
    _ = await svc.submit(sessionId: "s1", result: result())
    _ = await svc.submit(sessionId: "s2", result: result())
    XCTAssertEqual(svc.queuedCount, 2)
    net.offline = false
    net.gateFirstPost = true
    let flushing = Task { await svc.flush() }
    while net.gate == nil { await Task.yield() }          // the first POST is now suspended in the transport
    _ = await svc.turnOff()                                // the athlete turns the coach off meanwhile
    net.gate?.resume()
    await flushing.value
    XCTAssertEqual(net.posts, 1, "no further POST after turn-off")
    XCTAssertEqual(svc.debriefState(for: "s1"), .none, "no reply is written after turn-off")
    XCTAssertEqual(svc.debriefState(for: "s2"), .none)
    XCTAssertEqual(svc.queuedCount, 0)
    XCTAssertEqual(store.keys, [])
  }

  func testReconsentRestampsQueuedFactsSoTheyAreNotRefused() async throws {
    let net = FakeTransport.ok()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    _ = await svc.submit(sessionId: "s1", result: result())
    // consent on disk is from an older version, and the queued facts carry it
    var rec = try JSONDecoder().decode(CoachConsentRecord.self, from: store.data(forKey: "coach.consent")!)
    rec.version = CoachConsent.currentVersion - 1
    store.set(try JSONEncoder().encode(rec), forKey: "coach.consent")
    var q = try JSONDecoder().decode([CoachService.QueueItem].self, from: store.data(forKey: "coach.queue")!)
    q[0].facts = q[0].facts.withConsentVersion(CoachConsent.currentVersion - 1)
    store.set(try JSONEncoder().encode(q), forKey: "coach.queue")
    net.handler = FakeTransport.ok().handler
    _ = await svc.acceptReconsent()
    XCTAssertEqual(svc.queue.first?.facts.consentVersion, CoachConsent.currentVersion)
    await svc.flush()
    XCTAssertEqual(svc.debriefState(for: "s1"), .reply("Sled push took 4:20."))
  }

  func testAServerSideVersionBumpAsksAgainAndSendsNothing() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { r in
      r.path == "/v1/coach" ? CoachHTTPResponse(status: 403, body: Data(#"{"error":"consent_required","currentConsentVersion":9}"#.utf8))
                            : CoachHTTPResponse(status: 200, body: Data(#"{"deviceToken":"tok"}"#.utf8))
    }
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(svc.state, .needsUpdate, "this build cannot show consent version 9: no re-consent dead end")
    var before = net.requests.count
    _ = await svc.submit(sessionId: "s2", result: result())
    XCTAssertEqual(net.requests.count, before, "nothing is sent until the athlete updates")
    before = net.requests.count
    let kept = await svc.acceptReconsent()
    XCTAssertEqual(kept, .unavailable)
    XCTAssertEqual(net.requests.count, before, "no register call from a build that cannot show the new consent")
    _ = await svc.turnOff()                      // turning off is still possible
    XCTAssertEqual(svc.state, .off)
  }

  func testOneRefusedItemDoesNotBlockTheOthers() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    _ = await svc.submit(sessionId: "s1", result: result())
    _ = await svc.submit(sessionId: "s2", result: result())
    var calls = 0
    net.handler = { _ in
      calls += 1
      return calls == 1 ? CoachHTTPResponse(status: 403, body: Data(#"{"error":"install_mismatch"}"#.utf8))
                        : CoachHTTPResponse(status: 200, body: Data(#"{"reply":"ok","kind":"debrief","remainingToday":1}"#.utf8))
    }
    await svc.flush()
    XCTAssertEqual(svc.debriefState(for: "s2"), .reply("ok"))
  }

  func testQueueIsCapped() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    net.handler = { _ in throw Offline() }
    for i in 0..<(CoachService.maxQueue + 3) { _ = await svc.submit(sessionId: "s\(i)", result: result()) }
    XCTAssertEqual(svc.queuedCount, CoachService.maxQueue)
    XCTAssertEqual(svc.debriefState(for: "s0"), .error)
  }

  func testTurnOffFromAFlagOffBuildStillRemembersTheServerDelete() async {
    let store = MemoryCoachStore()
    let first = CoachService(config: on, transport: FakeTransport.ok(), store: store)
    _ = await first.turnOn()
    let off = CoachService(config: CoachConfig(), transport: FakeTransport.ok(), store: store)
    let out = await off.turnOff()
    XCTAssertEqual(out, .pending)
    XCTAssertTrue(off.hasPendingDelete)
    let later = CoachService(config: on, transport: FakeTransport.ok(), store: store)
    let retried = await later.retryPendingDelete()
    XCTAssertEqual(retried, .deleted(2))
  }

  func testServerForgettingTheInstallKeepsRepliesAlreadyRead() async {
    let net = FakeTransport.ok()
    let svc = CoachService(config: on, transport: net, store: MemoryCoachStore())
    _ = await svc.turnOn()
    _ = await svc.submit(sessionId: "s1", result: result())
    XCTAssertEqual(svc.debriefState(for: "s1"), .reply("Sled push took 4:20."))
    net.handler = { _ in CoachHTTPResponse(status: 401) }
    _ = await svc.submit(sessionId: "s2", result: result())
    XCTAssertEqual(svc.state, .off)
    XCTAssertTrue(svc.wasReset)
    XCTAssertEqual(svc.debriefState(for: "s1"), .reply("Sled push took 4:20."))
    net.handler = FakeTransport.ok().handler
    _ = await svc.turnOn()
    XCTAssertFalse(svc.wasReset)
  }

  func testKeepItOnThenTurnOffCannotResurrectConsent() async throws {
    let net = GatedTransport()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    var rec = try JSONDecoder().decode(CoachConsentRecord.self, from: store.data(forKey: "coach.consent")!)
    rec.version = CoachConsent.currentVersion - 1
    store.set(try JSONEncoder().encode(rec), forKey: "coach.consent")
    XCTAssertEqual(svc.state, .needsReconsent)
    net.gateNextRegister = true
    let keeping = Task { await svc.acceptReconsent() }
    while net.gate == nil { await Task.yield() }       // "Keep it on" is in flight
    _ = await svc.turnOff()                             // then "Turn off"
    net.gate?.resume()
    let result = await keeping.value
    XCTAssertEqual(result, .failed)
    XCTAssertEqual(svc.state, .off)
    XCTAssertEqual(store.keys, [], "consent is not written back after turn-off")
  }

  func testTurnOnInFlightThenTurnOffStaysOff() async {
    let net = GatedTransport()
    let store = MemoryCoachStore()
    let svc = CoachService(config: on, transport: net, store: store)
    _ = await svc.turnOn()
    net.gateNextRegister = true
    let second = Task { await svc.turnOn() }
    while net.gate == nil { await Task.yield() }
    _ = await svc.turnOff()
    net.gate?.resume()
    let r = await second.value
    XCTAssertEqual(r, .failed)
    XCTAssertEqual(svc.state, .off)
    XCTAssertEqual(store.keys, [])
  }
}
