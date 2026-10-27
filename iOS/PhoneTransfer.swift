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
  /// Sessions resumed after the app stopped, or closed from a checkpoint (manifest `resumed` > 0 or `recovered`). Read defensively:
  /// `resumed` may not exist in older folders or builds, in which case it counts as not resumed.
  @Published private(set) var recoveredIds: Set<String> = []
  /// True while a zip is being built. One zip at a time; incoming files wait (see `arrivals`) until it is done.
  @Published private(set) var exporting = false
  /// Incoming file renames queue here while a zip is built, so a zip never sees a file land mid-way.
  private let arrivals = ArrivalGate()
  private var stageSeq = 0
  /// Durable staging for files that arrive while a zip is built. Outside Documents/Sessions, so zips and the session list never see it.
  private static var incomingDir: URL? {
    (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
      .appendingPathComponent("incoming", isDirectory: true)
  }
  private static var exportsDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true) }
  /// Sessions the watch has announced and the phone has not completed. Unlike the watchdog, entries are not dropped after 24 h.
  @Published private(set) var announcedIds: Set<String> = []
  private let announcedKey = "announcedSessions"
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
    announcedIds = Set(UserDefaults.standard.stringArray(forKey: "announcedSessions") ?? [])
    super.init()
    // Nothing is receiving yet: a staged file left in tmp by an earlier run is an orphan, and old exports are dead.
    IncomingStage.sweepOrphans(inTemp: FileManager.default.temporaryDirectory)
    Self.removeStaleZips()
    refresh()
  }

  private func announce(_ ids: [String]) {
    let new = announcedIds.union(ids)
    guard new != announcedIds else { return }
    announcedIds = new
    UserDefaults.standard.set(Array(new), forKey: announcedKey)
  }

  private func unannounce(_ ids: Set<String>) {
    let new = announcedIds.subtracting(ids)
    guard new != announcedIds else { return }
    announcedIds = new
    UserDefaults.standard.set(Array(new), forKey: announcedKey)
  }

  /// The app came to the front: time spent closed does not count towards the 3 minutes.
  func appBecameActive() {
    reapplyStaged()
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
    unannounce(completeIds)
    saveWatchdog()
    evaluateSync()
    var records: [SessionRecord] = []
    for s in sessions where completeIds.contains(s.id) {
      if let r = try? CoachResult.load(inSessionFolder: root.appendingPathComponent(s.id)) {
        records.append(SessionRecord(id: s.id, result: r))
      }
    }
    let sorted = SessionRecord.sorted(records)
    let recovered = Set(sorted.map(\.id).filter { Self.wasRecovered(root.appendingPathComponent($0)) })
    if recovered != recoveredIds { recoveredIds = recovered }
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

  /// Sessions the watch has announced that have no folder on the phone yet: they exist on the watch only. Kept past the
  /// watchdog's 24 h, until the session arrives or the watch says it deleted it.
  var watchOnlyIds: [String] {
    let here = Set(sessions.map(\.id))
    return announcedIds.filter { !here.contains($0) }.sorted(by: >)
  }

  private static func manifestJSON(_ folder: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func wasRecovered(_ folder: URL) -> Bool {
    guard let m = manifestJSON(folder) else { return false }
    if let n = m["resumed"] as? Int, n > 0 { return true }
    if let b = m["resumed"] as? Bool, b { return true }
    return m["recovered"] as? Bool == true
  }

  /// Athlete code and start time for the delete confirmation. Either can be missing.
  func describe(_ id: String) -> (athlete: String?, date: Date?) {
    guard let root = Self.root, let m = Self.manifestJSON(root.appendingPathComponent((id as NSString).lastPathComponent)) else { return (nil, nil) }
    let date = (m["startedAtEpochMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    return (m["athlete"] as? String, date)
  }

  func delete(_ id: String) {
    guard !exporting, let root = Self.root else { return }
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

  enum ExportError: Error { case busy }

  /// A zip for the share sheet, built off the main thread. `sessionId` nil is every session (the whole Sessions folder: complete
  /// sessions, partial folders and the phone's correction files), named `station-coach-<date>.zip`; otherwise `<id>.zip`.
  /// One at a time: a second call while one runs throws `.busy`. Incoming files are held (not renamed into the folder) until the
  /// zip is done, then applied in order, so a zip is a consistent snapshot. Nothing is sent anywhere but the share sheet.
  @MainActor
  func exportZip(sessionId: String? = nil, now: Date = Date()) async throws -> URL {
    guard !exporting else { throw ExportError.busy }
    guard let root = Self.root else { throw CocoaError(.fileNoSuchFile) }
    exporting = true
    arrivals.close()
    Self.removeStaleZips()
    let source = sessionId.map { root.appendingPathComponent(($0 as NSString).lastPathComponent) } ?? root
    let name = sessionId.map { ($0 as NSString).lastPathComponent + ".zip" } ?? "station-coach-\(Self.dayStamp(now)).zip"
    let result = await Task.detached(priority: .userInitiated) { Result { try Self.buildZip(of: source, named: name) } }.value
    exporting = false
    arrivals.open()
    return try result.get()
  }

  /// Removes a shared zip once the share sheet is dismissed.
  func discardExport(_ url: URL) { try? FileManager.default.removeItem(at: url) }

  private static func dayStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  /// Every zip this app wrote lives in `tmp/exports`, so emptying it also catches zips of sessions since deleted.
  /// Zips from before that folder existed sit directly in tmp, named `station-coach-*.zip` or `<session id>.zip`.
  private static func removeStaleZips() {
    let fm = FileManager.default
    try? fm.removeItem(at: exportsDir)
    let tmp = fm.temporaryDirectory
    for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasSuffix(".zip") {
      if name.hasPrefix("station-coach-") || name.contains("Z-") { try? fm.removeItem(at: tmp.appendingPathComponent(name)) }
    }
  }

  private static func buildZip(of source: URL, named name: String) throws -> URL {
    var coordinationError: NSError?
    var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
    NSFileCoordinator().coordinate(readingItemAt: source, options: [.forUploading], error: &coordinationError) { zipped in
      let dest = exportsDir.appendingPathComponent(name)
      do {
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        // The coordinator's zip is ours to move; a copy would leave two zips on disk.
        try FileManager.default.moveItem(at: zipped, to: dest)
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
    DispatchQueue.main.async {
      self.reapplyStaged() // acks need an activated session
      self.updateWatchInstalled()
    }
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
      self.announce(ids.map { ($0 as NSString).lastPathComponent })
      for id in ids.map({ ($0 as NSString).lastPathComponent }) { self.watchdog.activity(session: id, at: now) }
      self.refresh()
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    if let gone = userInfo["gone"] as? [String] { // sessions deleted on the watch
      DispatchQueue.main.async {
        self.unannounce(Set(gone.map { ($0 as NSString).lastPathComponent }))
        for id in gone.map({ ($0 as NSString).lastPathComponent }) { self.watchdog.complete(session: id) }
        self.refresh()
      }
      return
    }
    guard let id = (userInfo["finished"] as? String).map({ ($0 as NSString).lastPathComponent }), !id.isEmpty, id != ".." else { return }
    DispatchQueue.main.async {
      if !self.tracker.isComplete(id) { self.announce([id]) }
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
      guard self.arrivals.isClosed else {
        self.apply(staged: staged, sid: sid, name: name, bytes: bytes, total: total)
        return
      }
      // A zip is being built. Park the file where a kill cannot lose it (the name carries what `apply` needs), and apply it
      // when the gate opens. If the app dies first, `reapplyStaged` finds it on the next launch.
      var url = staged
      self.stageSeq = max(self.stageSeq + 1, Int(Date().timeIntervalSince1970 * 1000))
      if let dir = Self.incomingDir,
         let durable = try? IncomingStage.stage(staged, entry: IncomingEntry(sid: sid, name: name, bytes: bytes, total: total), seq: self.stageSeq, into: dir) {
        url = durable
      }
      self.arrivals.submit { self.apply(staged: url, sid: sid, name: name, bytes: bytes, total: total) }
    }
  }

  /// Applies files left in durable staging by a run that was killed during a zip, oldest first. Only when no zip is running:
  /// while one runs, the files in staging belong to the in-memory queue.
  private func reapplyStaged() {
    guard !arrivals.isClosed, WCSession.isSupported(), WCSession.default.activationState == .activated, let dir = Self.incomingDir else { return }
    for item in IncomingStage.pending(in: dir) {
      apply(staged: item.url, sid: item.entry.sid, name: item.entry.name, bytes: item.entry.bytes, total: item.entry.total)
    }
  }

  /// Drops a "On watch only" row the user knows is gone (the watch was wiped or reinstalled).
  func forgetWatchOnly(_ id: String) { unannounce([id]) }

  /// Moves a staged incoming file into its session folder. Runs on main, never while a zip is being built (see `arrivals`).
  private func apply(staged: URL, sid: String, name: String, bytes: Int, total: Int) {
    let fm = FileManager.default
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
