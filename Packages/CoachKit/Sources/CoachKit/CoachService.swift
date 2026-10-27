import Foundation

/// The phone side of the optional AI coach: consent, an offline queue and the replies. Nothing here touches the network
/// itself: every request goes through a `CoachTransport`, which is a fake in tests and a thin URLSession wrapper in the app.
/// With the flag off, or with no base URL, nothing is ever sent and no state is written.

public enum CoachConsent {
  /// The consent screen this build shows. The service refuses facts that carry any other version.
  public static let currentVersion = 1
}

public struct CoachConfig: Equatable {
  public var enabled: Bool
  public var baseURL: String

  public init(enabled: Bool = false, baseURL: String = "") {
    self.enabled = enabled
    self.baseURL = baseURL
  }

  /// Flag on AND a base URL set. Both default to off/empty, so a build that sets neither makes no calls.
  public var isAvailable: Bool { enabled && !baseURL.isEmpty }
}

public struct CoachHTTPRequest: Equatable {
  public let method: String
  public let path: String
  public let bearer: String?
  public let body: Data?
}

public struct CoachHTTPResponse: Equatable {
  public let status: Int
  public let body: Data
  public init(status: Int, body: Data = Data()) {
    self.status = status
    self.body = body
  }
}

public protocol CoachTransport {
  func send(_ request: CoachHTTPRequest) async throws -> CoachHTTPResponse
}

/// Small persistent store. `UserDefaults` in the app, a dictionary in tests.
public protocol CoachStore: AnyObject {
  func data(forKey key: String) -> Data?
  func set(_ data: Data?, forKey key: String)
}

public final class MemoryCoachStore: CoachStore {
  private var values: [String: Data] = [:]
  public init() {}
  public func data(forKey key: String) -> Data? { values[key] }
  public func set(_ data: Data?, forKey key: String) { values[key] = data }
  public var keys: [String] { values.keys.sorted() }
}

/// What consent looks like on disk. `token` is the device token the service issued.
public struct CoachConsentRecord: Codable, Equatable {
  public var version: Int
  public var installId: String
  /// Day only, "2026-10-27".
  public var since: String
  public var token: String
}

public enum CoachState: Equatable {
  /// Flag off, no base URL, or the athlete has not turned the coach on.
  case off
  case on(since: String)
  /// The consent text changed. Nothing is sent until the athlete answers.
  case needsReconsent
  /// The service wants a newer consent than this build can show. Only "Turn off" makes sense until the app is updated.
  case needsUpdate
}

/// How one session's debrief looks on the session detail.
public enum DebriefState: Equatable {
  case none
  case queued
  case reply(String)
  case error
  case cap
}

public enum TurnOnResult: Equatable {
  case on
  case failed
  case unavailable
}

public enum TurnOffResult: Equatable {
  /// The service confirmed; it deleted this many sessions.
  case deleted(Int)
  /// Local data is gone already; the service delete will be retried.
  case pending
}

@MainActor
public final class CoachService {
  struct QueueItem: Codable, Equatable {
    var sessionId: String
    var facts: CoachFacts
    var attempts: Int
  }

  private struct PendingDelete: Codable { var token: String }
  private struct RegisterBody: Encodable { let installId: String; let consentVersion: Int }
  private struct RegisterReply: Decodable { let deviceToken: String }
  private struct CoachReplyBody: Decodable { let reply: String }
  private struct DeleteReply: Decodable { let deletedSessions: Int }
  private struct ErrorBody: Decodable { let currentConsentVersion: Int? }

  static let consentKey = "coach.consent"
  static let queueKey = "coach.queue"
  static let repliesKey = "coach.replies"
  static let statesKey = "coach.states"
  static let pendingDeleteKey = "coach.pendingDelete"
  static let serverVersionKey = "coach.serverVersion"
  static let resetKey = "coach.reset"
  static let maxAttempts = 3
  /// Facts waiting for a connection. Past this the oldest is dropped (shown as the error state).
  static let maxQueue = 20

  private static func encoded<T: Encodable>(_ value: T, emptyIsNil: Bool) -> Data? {
    if emptyIsNil { return nil }
    return try? JSONEncoder().encode(value)
  }

  public let config: CoachConfig
  private let transport: CoachTransport
  private let store: CoachStore
  private let calendar: Calendar
  private let now: () -> Date
  /// Bumped whenever consent is replaced or cleared. A send that was in flight when it changed drops its result.
  private var epoch = 0

  public init(config: CoachConfig, transport: CoachTransport, store: CoachStore, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
    self.config = config
    self.transport = transport
    self.store = store
    self.calendar = calendar
    self.now = now
  }

  // MARK: State

  private var consent: CoachConsentRecord? {
    store.data(forKey: Self.consentKey).flatMap { try? JSONDecoder().decode(CoachConsentRecord.self, from: $0) }
  }

  public var state: CoachState {
    guard config.isAvailable, let c = consent else { return .off }
    if let sv = serverVersion, sv > CoachConsent.currentVersion { return .needsUpdate }
    if c.version != CoachConsent.currentVersion { return .needsReconsent }
    return .on(since: c.since)
  }

  /// The consent version the service last said it wants, when it is ahead of this build's.
  private var serverVersion: Int? {
    store.data(forKey: Self.serverVersionKey).flatMap { try? JSONDecoder().decode(Int.self, from: $0) }
  }

  /// The service forgot this install (for example after 30 idle days) and the coach was switched off. Replies already
  /// read are kept; the athlete can turn the coach on again. Cleared by turning on or off.
  public var wasReset: Bool { store.data(forKey: Self.resetKey) != nil }

  var queue: [QueueItem] {
    get { store.data(forKey: Self.queueKey).flatMap { try? JSONDecoder().decode([QueueItem].self, from: $0) } ?? [] }
    set { store.set(Self.encoded(newValue, emptyIsNil: newValue.isEmpty), forKey: Self.queueKey) }
  }

  public var queuedCount: Int { queue.count }

  private var replies: [String: String] {
    get { store.data(forKey: Self.repliesKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
    set { store.set(Self.encoded(newValue, emptyIsNil: newValue.isEmpty), forKey: Self.repliesKey) }
  }

  /// "error" or "cap" for sessions whose last attempt ended that way.
  private var endStates: [String: String] {
    get { store.data(forKey: Self.statesKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
    set { store.set(Self.encoded(newValue, emptyIsNil: newValue.isEmpty), forKey: Self.statesKey) }
  }

  public func debriefState(for sessionId: String) -> DebriefState {
    if let r = replies[sessionId] { return .reply(r) }
    if queue.contains(where: { $0.sessionId == sessionId }) { return .queued }
    switch endStates[sessionId] {
    case "cap": return .cap
    case "error": return .error
    default: return .none
    }
  }

  /// A pending service-side delete from an earlier turn-off that could not reach the server.
  public var hasPendingDelete: Bool { store.data(forKey: Self.pendingDeleteKey) != nil }

  // MARK: Consent

  private func day() -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: now())
    return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
  }

  private func request(_ method: String, _ path: String, bearer: String? = nil, body: (any Encodable)? = nil) -> CoachHTTPRequest {
    CoachHTTPRequest(method: method, path: path, bearer: bearer, body: body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) })
  }

  /// Turn the coach on. Consent is recorded only once the service confirms it.
  public func turnOn() async -> TurnOnResult {
    guard config.isAvailable else { return .unavailable }
    let epoch0 = epoch
    let install = UUID().uuidString.lowercased()
    let req = request("POST", "/v1/register", body: RegisterBody(installId: install, consentVersion: CoachConsent.currentVersion))
    guard let res = try? await transport.send(req), res.status == 200,
          let token = try? JSONDecoder().decode(RegisterReply.self, from: res.body).deviceToken else { return .failed }
    guard epoch == epoch0 else { return .failed }   // consent was turned off or replaced while this was in flight
    store.set(nil, forKey: Self.resetKey)
    save(CoachConsentRecord(version: CoachConsent.currentVersion, installId: install, since: day(), token: token))
    return .on
  }

  /// Answer the re-consent screen with "Keep it on": re-register this install with its current token at the new version.
  public func acceptReconsent() async -> TurnOnResult {
    guard config.isAvailable, var c = consent else { return .unavailable }
    if case .needsUpdate = state { return .unavailable }   // this build cannot show the newer consent
    let epoch0 = epoch
    let req = request("POST", "/v1/register", bearer: c.token, body: RegisterBody(installId: c.installId, consentVersion: CoachConsent.currentVersion))
    guard let res = try? await transport.send(req), res.status == 200,
          let token = try? JSONDecoder().decode(RegisterReply.self, from: res.body).deviceToken else { return .failed }
    guard epoch == epoch0, consent?.installId == c.installId else { return .failed }   // turned off while in flight: stay off
    c.version = CoachConsent.currentVersion
    c.token = token
    save(c)
    store.set(nil, forKey: Self.serverVersionKey)
    // Facts queued under the old version would be refused: stamp them with the one the athlete just accepted.
    queue = queue.map { QueueItem(sessionId: $0.sessionId, facts: $0.facts.withConsentVersion(c.version), attempts: 0) }
    return .on
  }

  /// Turn the coach off. Everything held locally goes at once, whether or not the service can be reached.
  public func turnOff() async -> TurnOffResult {
    guard let c = consent else { clearLocal(); return .deleted(0) }
    clearLocal()
    // Even with the flag off in this build, remember the delete so a later build can finish it.
    guard config.isAvailable else {
      store.set(try? JSONEncoder().encode(PendingDelete(token: c.token)), forKey: Self.pendingDeleteKey)
      return .pending
    }
    return await deleteRemote(token: c.token)
  }

  /// Try an earlier turn-off's service delete again (call on app open).
  @discardableResult
  public func retryPendingDelete() async -> TurnOffResult? {
    guard config.isAvailable, let data = store.data(forKey: Self.pendingDeleteKey),
          let p = try? JSONDecoder().decode(PendingDelete.self, from: data) else { return nil }
    return await deleteRemote(token: p.token)
  }

  private func deleteRemote(token: String) async -> TurnOffResult {
    if let res = try? await transport.send(request("DELETE", "/v1/data", bearer: token)) {
      if res.status == 200 {
        store.set(nil, forKey: Self.pendingDeleteKey)
        return .deleted((try? JSONDecoder().decode(DeleteReply.self, from: res.body).deletedSessions) ?? 0)
      }
      if res.status == 401 {   // the service no longer knows this install: nothing is held
        store.set(nil, forKey: Self.pendingDeleteKey)
        return .deleted(0)
      }
    }
    store.set(try? JSONEncoder().encode(PendingDelete(token: token)), forKey: Self.pendingDeleteKey)
    return .pending
  }

  private func save(_ c: CoachConsentRecord) {
    epoch += 1
    store.set(try? JSONEncoder().encode(c), forKey: Self.consentKey)
  }

  /// Turning off: everything held locally goes.
  private func clearLocal() {
    epoch += 1
    for key in [Self.consentKey, Self.queueKey, Self.repliesKey, Self.statesKey, Self.serverVersionKey, Self.resetKey] {
      store.set(nil, forKey: key)
    }
  }

  /// The service no longer knows this install: consent and the queue go, replies already read stay.
  private func resetAfterServerForgot() {
    epoch += 1
    for key in [Self.consentKey, Self.queueKey, Self.statesKey, Self.serverVersionKey] { store.set(nil, forKey: key) }
    store.set(Data("1".utf8), forKey: Self.resetKey)
  }

  // MARK: Debriefs

  /// Queue the facts for a finished session and try to send. Does nothing unless the coach is on at the current version.
  @discardableResult
  public func submit(sessionId: String, result: CoachResult) async -> DebriefState {
    guard case .on = state, let c = consent else { return .none }
    if replies[sessionId] != nil || queue.contains(where: { $0.sessionId == sessionId }) { return debriefState(for: sessionId) }
    let facts = CoachFacts.make(from: result, installId: c.installId, consentVersion: c.version, calendar: calendar)
    var states = endStates
    states[sessionId] = nil
    endStates = states
    var q = queue + [QueueItem(sessionId: sessionId, facts: facts, attempts: 0)]
    while q.count > Self.maxQueue {
      var s = endStates
      s[q[0].sessionId] = "error"
      endStates = s
      q.removeFirst()
    }
    queue = q
    await flush()
    return debriefState(for: sessionId)
  }

  /// Send what is queued, oldest first. Stops at the first network failure so the rest wait for a connection.
  /// Turning the coach off (or replacing consent) while a send is in flight stops the loop and drops the result:
  /// no further request goes out and no reply is written.
  public func flush() async {
    guard case .on = state, let c = consent else { return }
    let epoch0 = epoch
    for item in queue {
      guard epoch == epoch0, queue.contains(where: { $0.sessionId == item.sessionId }) else { return }
      guard let body = try? JSONEncoder().encode(item.facts),
            let res = try? await transport.send(CoachHTTPRequest(method: "POST", path: "/v1/coach", bearer: c.token, body: body)) else { return }
      guard epoch == epoch0 else { return }
      switch res.status {
      case 200:
        if let reply = try? JSONDecoder().decode(CoachReplyBody.self, from: res.body).reply {
          var r = replies
          r[item.sessionId] = reply
          replies = r
          finish(item.sessionId, endState: nil)
        } else {
          fail(item)
        }
      case 429:   // today's debriefs are used up: show the cap state and do not retry this session
        finish(item.sessionId, endState: "cap")
      case 401:   // the service no longer knows this install (for example after 30 idle days): back to off, keep read replies
        resetAfterServerForgot()
        return
      case 403:
        if let sv = (try? JSONDecoder().decode(ErrorBody.self, from: res.body))?.currentConsentVersion, sv > CoachConsent.currentVersion {
          // The service wants a newer consent than this build knows: ask again, send nothing until answered.
          store.set(try? JSONEncoder().encode(sv), forKey: Self.serverVersionKey)
          return
        }
        if item.facts.consentVersion != c.version {   // stamped under an older consent: fix this item, do not block the rest
          queue = queue.map { $0.sessionId == item.sessionId ? QueueItem(sessionId: $0.sessionId, facts: $0.facts.withConsentVersion(c.version), attempts: $0.attempts + 1) : $0 }
        } else {
          fail(item)
        }
      default:
        fail(item)
      }
    }
  }

  private func finish(_ sessionId: String, endState: String?) {
    queue = queue.filter { $0.sessionId != sessionId }
    if let endState {
      var s = endStates
      s[sessionId] = endState
      endStates = s
    }
  }

  private func fail(_ item: QueueItem) {
    if item.attempts + 1 >= Self.maxAttempts {
      finish(item.sessionId, endState: "error")
    } else {
      queue = queue.map { $0.sessionId == item.sessionId ? QueueItem(sessionId: $0.sessionId, facts: $0.facts, attempts: $0.attempts + 1) : $0 }
    }
  }
}

private struct AnyEncodable: Encodable {
  let value: any Encodable
  init(_ value: any Encodable) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
