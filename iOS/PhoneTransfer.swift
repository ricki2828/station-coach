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
  /// Training load for every complete session, from `coach.json` and `hr.csv`. Rebuilt whenever the sessions change.
  @Published private(set) var loadSummary = TrainingLoad.summarise([], now: Date())
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
  /// Parsed `hr.csv` by session id (an empty series when the session has none). Touched on the main thread only.
  /// A complete session is never overwritten (a re-send is dropped and re-acked), so a cached series cannot go stale;
  /// if that rule is ever relaxed, the key must include the file's size or modification time.
  private var hrCache: [String: HeartRateSeries] = [:]
  private var loadGeneration = 0
  private var noticeGate = NoticeRescheduleGate()
  private var loadBuiltAt = Date.distantPast

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
    // The 180-day max-heart-rate and calibration windows move with the date, not only with new sessions.
    if !Calendar.current.isDate(loadBuiltAt, inSameDayAs: Date()), let root = Self.root { rebuildLoad(coachSessions, root: root) }
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
      if let r = try? CoachResult.load(inSessionFolder: root.appendingPathComponent(s.id)) {
        records.append(SessionRecord(id: s.id, result: r))
      }
    }
    let sorted = SessionRecord.sorted(records)
    if sorted != coachSessions {
      coachSessions = sorted
      rebuildLoad(sorted, root: root)
    } else if sorted.isEmpty {
      noticeGate.loadLanded() // nothing to wait for
    }
    updateWatchInstalled()
    rescheduleNotice()
  }

  /// Training load for `records`. The `hr.csv` files are read and the load computed off the main thread; the result lands
  /// on the main thread, and the Monday notification is rebuilt from it. A newer rebuild supersedes an older one.
  private func rebuildLoad(_ records: [SessionRecord], root: URL) {
    loadGeneration += 1
    let generation = loadGeneration
    let known = hrCache
    Task.detached(priority: .utility) { [weak self] in
      var added: [String: HeartRateSeries] = [:]
      let inputs = records.map { r -> LoadInput in
        let series = known[r.id] ?? HeartRateSeries.load(url: root.appendingPathComponent(r.id).appendingPathComponent("hr.csv")) ?? HeartRateSeries(samples: [])
        if known[r.id] == nil { added[r.id] = series }
        return LoadInput(record: r, hr: series.isEmpty ? nil : series)
      }
      let summary = TrainingLoad.summarise(inputs, now: Date())
      await MainActor.run {
        guard let self, generation == self.loadGeneration else { return }
        for (id, series) in added { self.hrCache[id] = series }
        self.loadBuiltAt = Date()
        self.loadSummary = summary
        self.noticeGate.loadLanded()
        self.rescheduleNotice()
      }
    }
  }

  /// Sessions the watch is still sending: ones it announced, or a partial folder that started recently. An abandoned partial
  /// folder is not "unsent". Sessions the watch has not announced are invisible to the phone.
  private var watchHasUnsent: Bool {
    UnsentSessions.hasUnsent(partialIds: sessions.map(\.id).filter { !completeIds.contains($0) },
                             pendingIds: watchdog.pending.filter { !completeIds.contains($0) }, now: Date())
  }

  /// Rebuild the Monday notification from what is on the phone now. Called after every refresh and every load rebuild, so a
  /// file that arrives in the background updates it without any view being on screen.
  func rescheduleNotice(now: Date = Date()) {
    // Not before the first load has landed: an empty list would cancel the pending notification.
    guard noticeGate.mayReschedule else { return }
    let sessions = loadSummary.sessions
    let unsent = watchHasUnsent
    Task { @MainActor in WeeklyNotifier.shared.reschedule(sessions: sessions, watchHasUnsent: unsent, now: now) }
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
    hrCache[id] = nil
    watchdog.complete(session: id)
    refresh()
  }

  /// Saves the Edit count sheet's result to the phone-only sidecar, then refreshes every screen that reads it.
  /// False when it could not be saved.
  @discardableResult
  func saveCorrection(_ correction: WallBallCorrection, for id: String) -> Bool {
    guard let root = Self.root else { return false }
    do {
      try CoachResult.saveCorrection(correction, inSessionFolder: root.appendingPathComponent((id as NSString).lastPathComponent))
    } catch {
      return false
    }
    refresh()
    return true
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
    // The temporary file is deleted when this returns, so move it to a staging file now. The decision (tracker state lives on main)
    // is made after the hop, with no blocking wait on the delegate queue.
    let fm = FileManager.default
    let staged = fm.temporaryDirectory.appendingPathComponent("incoming-\(UUID().uuidString)")
    do { try fm.moveItem(at: file.fileURL, to: staged) } catch { return }
    DispatchQueue.main.async {
      // A session already complete on the phone is never overwritten (a watch re-send carries no new data): just re-ack.
      if self.tracker.isComplete(sid) {
        try? fm.removeItem(at: staged)
        WCSession.default.transferUserInfo(["ack": sid])
        return
      }
      guard let root = Self.root else { try? fm.removeItem(at: staged); return }
      let folder = root.appendingPathComponent(sid, isDirectory: true)
      let dest = folder.appendingPathComponent(name)
      var actual = -1
      do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staged, to: dest)
        actual = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.intValue ?? -1
      } catch {
        try? fm.removeItem(at: staged)
        return
      }
      self.watchdog.fileArrived(session: sid, at: Date().timeIntervalSinceReferenceDate)
      self.tracker.received(session: sid, name: name, expectedBytes: bytes, actualBytes: actual, total: total)
      if let data = try? JSONEncoder().encode(self.tracker) { UserDefaults.standard.set(data, forKey: self.trackerKey) }
      if self.tracker.isComplete(sid) { WCSession.default.transferUserInfo(["ack": sid]) }
      self.refresh()
    }
  }
}
