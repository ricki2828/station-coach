import CoachKit
import CoachUI
import Foundation
import WatchConnectivity

/// Receives session files from the watch into `Documents/Sessions/<id>/`, acks a session once every
/// file has arrived at its announced size, and lists what is on the phone.
final class PhoneTransfer: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = PhoneTransfer()

  @Published private(set) var sessions: [SessionSummary] = []
  @Published private(set) var completeIds: Set<String> = []
  @Published private(set) var sendState: SendState = .idle
  /// Every complete session that has a `coach.json`, newest first.
  @Published private(set) var coachSessions: [SessionRecord] = []
  @Published private(set) var watchAppInstalled = false
  /// Percent of the newest not-yet-complete transfer, if one is in flight.
  @Published private(set) var syncPercent: Int?

  /// The newest finished session that has gone quiet for 3 minutes while the app is open.
  @Published private(set) var syncFailedId: String?

  private let trackerKey = "transferTracker"
  private let watchdogKey = "syncWatchdog"
  private var tracker: TransferTracker
  private var watchdog: SyncWatchdog
  private var openedAt = Date().timeIntervalSinceReferenceDate
  private var syncTimer: Timer?

  override init() {
    if let data = UserDefaults.standard.data(forKey: "transferTracker"),
       let t = try? JSONDecoder().decode(TransferTracker.self, from: data) {
      tracker = t
    } else {
      tracker = TransferTracker()
    }
    if let data = UserDefaults.standard.data(forKey: "syncWatchdog"), let w = try? JSONDecoder().decode(SyncWatchdog.self, from: data) {
      watchdog = w
    } else {
      watchdog = SyncWatchdog()
    }
    super.init()
    refresh()
  }

  /// The app came to the front: time spent closed does not count towards the 3 minutes.
  func appBecameActive() {
    openedAt = Date().timeIntervalSinceReferenceDate
    refresh()
  }

  private func saveWatchdog() {
    if let data = try? JSONEncoder().encode(watchdog) { UserDefaults.standard.set(data, forKey: watchdogKey) }
  }

  private func evaluateSync() {
    let now = Date().timeIntervalSinceReferenceDate
    watchdog.prune(now: now)
    syncFailedId = watchdog.failedSession(now: now, openSince: openedAt)
  }

  static var root: URL? { try? SessionFiles.defaultRoot() }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
    syncTimer?.invalidate()
    syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.evaluateSync() }
  }

  func refresh() {
    guard let root = Self.root else { return }
    sessions = SessionFiles.summaries(in: root)
    completeIds = Set(sessions.map(\.id).filter { tracker.isComplete($0) })
    syncPercent = sessions.map(\.id).first { !tracker.isComplete($0) && tracker.progress($0) != nil }.flatMap { tracker.progress($0) }
    for id in watchdog.pending where completeIds.contains(id) { watchdog.complete(session: id) }
    saveWatchdog()
    evaluateSync()
    var records: [SessionRecord] = []
    for s in sessions where completeIds.contains(s.id) {
      let url = root.appendingPathComponent(s.id).appendingPathComponent(CoachResult.fileName)
      if let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(CoachResult.self, from: data) {
        records.append(SessionRecord(id: s.id, result: r))
      }
    }
    let sorted = SessionRecord.sorted(records)
    if sorted != coachSessions { coachSessions = sorted }
    updateWatchInstalled()
  }

  /// Sends the plan to the watch as application context (the latest one wins; delivered when the watch is next awake).
  func sendPlan(_ plan: SessionPlan) {
    guard WCSession.isSupported() else { sendState = .failed; return }
    let s = WCSession.default
    guard s.activationState == .activated else {
      sendState = .failed
      activate()
      return
    }
    guard s.isPaired, s.isWatchAppInstalled else { sendState = .watchAppMissing; return }
    sendState = .sending(watchName: "Apple Watch")
    do {
      let data = try JSONEncoder().encode(plan)
      try s.updateApplicationContext(["plan": String(decoding: data, as: UTF8.self)])
      sendState = .sent
    } catch {
      sendState = .failed
    }
  }

  func resetSendState() { if sendState != .idle { sendState = .idle } }

  func delete(_ id: String) {
    guard let root = Self.root else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    watchdog.complete(session: id)
    refresh()
  }

  /// Saves the Edit count sheet's result into the session's `coach.json`, then refreshes every screen that reads it.
  func saveCorrection(_ correction: WallBallCorrection, for id: String) {
    guard let root = Self.root else { return }
    _ = try? CoachResult.saveCorrection(correction, inSessionFolder: root.appendingPathComponent((id as NSString).lastPathComponent))
    refresh()
  }

  /// A zip of the session folder in the temp directory, for the share sheet.
  func zip(_ id: String) throws -> URL {
    guard let root = Self.root else { throw CocoaError(.fileNoSuchFile) }
    let folder = root.appendingPathComponent(id)
    var coordinationError: NSError?
    var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
      let dest = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".zip")
      do {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: zipped, to: dest)
        result = .success(dest)
      } catch {
        result = .failure(error)
      }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }

  // MARK: WCSessionDelegate

  private func updateWatchInstalled() {
    guard WCSession.isSupported() else { return }
    let s = WCSession.default
    let installed = s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
    if installed != watchAppInstalled { watchAppInstalled = installed }
  }

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    DispatchQueue.main.async { self.updateWatchInstalled() }
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    DispatchQueue.main.async { self.updateWatchInstalled() }
  }
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { session.activate() }

  /// The watch's heartbeat while files are still outstanding: each one restarts the clock.
  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let ids = applicationContext["sending"] as? [String] else { return }
    DispatchQueue.main.async {
      let now = Date().timeIntervalSinceReferenceDate
      for id in ids.map({ ($0 as NSString).lastPathComponent }) { self.watchdog.activity(session: id, at: now) }
      self.refresh()
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    if let gone = userInfo["gone"] as? [String] { // sessions deleted on the watch
      DispatchQueue.main.async {
        for id in gone.map({ ($0 as NSString).lastPathComponent }) { self.watchdog.complete(session: id) }
        self.refresh()
      }
      return
    }
    guard let id = (userInfo["finished"] as? String).map({ ($0 as NSString).lastPathComponent }), !id.isEmpty, id != ".." else { return }
    DispatchQueue.main.async {
      if !self.tracker.isComplete(id) {
        self.watchdog.finished(session: id, at: Date().timeIntervalSinceReferenceDate)
      }
      self.refresh()
    }
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    guard let md = file.metadata,
          let sid = (md["session"] as? String).map({ ($0 as NSString).lastPathComponent }),
          let name = (md["name"] as? String).map({ ($0 as NSString).lastPathComponent }),
          let bytes = md["bytes"] as? Int, let total = md["total"] as? Int,
          !sid.isEmpty, !name.isEmpty, sid != "..", name != ".." else { return }
    // The temporary file is deleted when this returns, so move it now.
    guard let root = Self.root else { return }
    let folder = root.appendingPathComponent(sid, isDirectory: true)
    let dest = folder.appendingPathComponent(name)
    var actual = -1
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: file.fileURL, to: dest)
      actual = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.intValue ?? -1
    } catch {
      return
    }
    DispatchQueue.main.async {
      self.watchdog.fileArrived(session: sid, at: Date().timeIntervalSinceReferenceDate)
      self.tracker.received(session: sid, name: name, expectedBytes: bytes, actualBytes: actual, total: total)
      if let data = try? JSONEncoder().encode(self.tracker) { UserDefaults.standard.set(data, forKey: self.trackerKey) }
      if self.tracker.isComplete(sid) { WCSession.default.transferUserInfo(["ack": sid]) }
      self.refresh()
    }
  }
}
