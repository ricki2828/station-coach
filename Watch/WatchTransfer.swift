import CoachKit
import Foundation
import WatchConnectivity

/// Sends finished session folders to the phone, one `transferFile` per file, and keeps them on
/// the watch until the phone answers with an ack for that session id.
final class WatchTransfer: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WatchTransfer()

  @Published private(set) var acked: Set<String>
  /// The plan the phone sent, kept across launches.
  @Published private(set) var plan: SessionPlan?
  /// True once the phone connection has answered at least once (so "no plan" is a fact, not a loading state).
  @Published private(set) var planChecked = false
  /// The folder being recorded right now; never sent.
  var activeSessionId: String?

  private let ackKey = "ackedSessions"
  private var heartbeat: Timer?

  override init() {
    acked = Set(UserDefaults.standard.stringArray(forKey: "ackedSessions") ?? [])
    if let json = UserDefaults.standard.string(forKey: "coachPlan"), let data = json.data(using: .utf8) {
      plan = try? JSONDecoder().decode(SessionPlan.self, from: data)
    }
    super.init()
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
    heartbeat?.invalidate()
    heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendHeartbeat() }
  }

  /// While files are outstanding, tells the phone which sessions are still sending. The phone gets no progress
  /// events for a single large file, and would otherwise call a slow transfer failed.
  func sendHeartbeat() {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
    let ids = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["session"] as? String })
    guard !ids.isEmpty else { return }
    try? WCSession.default.updateApplicationContext(["sending": ids.sorted(), "at": Date().timeIntervalSince1970])
  }

  /// Queues every finished, un-acked session. Safe to call repeatedly: files already queued are skipped.
  func sendUnsent() {
    // Never while recording: a large transfer competes with the AirPods link and the battery.
    guard activeSessionId == nil, WCSession.isSupported(), WCSession.default.activationState == .activated,
          let root = try? SessionFiles.defaultRoot() else { return }
    let unfinished = Set(SessionFiles.unfinished(in: root))
    let queued = Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL })
    for summary in SessionFiles.summaries(in: root) where !unfinished.contains(summary.id) && !acked.contains(summary.id) {
      let folder = root.appendingPathComponent(summary.id)
      guard let files = try? SessionFiles.list(folder) else { continue }
      for f in files {
        let url = folder.appendingPathComponent(f.name)
        if queued.contains(url) { continue }
        WCSession.default.transferFile(url, metadata: ["session": summary.id, "name": f.name, "bytes": f.bytes, "total": files.count])
      }
    }
    sendHeartbeat() // "Send unsent" restarts the phone's clock
  }

  /// Tells the phone a session is closed and on its way, so the phone can say so if the files never come.
  func announceFinished(_ id: String) {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
    WCSession.default.transferUserInfo(["finished": id])
  }

  /// Called when a recording starts: drops queued transfers so nothing runs during the session.
  /// `sendUnsent()` re-queues them afterwards.
  func pauseForRecording() {
    guard WCSession.isSupported() else { return }
    WCSession.default.outstandingFileTransfers.forEach { $0.cancel() }
  }

  func deleteAcked() {
    guard let root = try? SessionFiles.defaultRoot() else { return }
    for id in acked { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
    if !acked.isEmpty, WCSession.isSupported(), WCSession.default.activationState == .activated {
      WCSession.default.transferUserInfo(["gone": Array(acked)]) // the phone clears anything it was waiting for
    }
    objectWillChange.send()
  }

  func isAcked(_ id: String) -> Bool { acked.contains(id) }

  // MARK: WCSessionDelegate

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    if activationState == .activated {
      sendUnsent()
      apply(session.receivedApplicationContext)
    }
    DispatchQueue.main.async { self.planChecked = true }
  }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    apply(applicationContext)
  }

  private func apply(_ context: [String: Any]) {
    guard let json = context["plan"] as? String, let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(SessionPlan.self, from: data) else { return }
    DispatchQueue.main.async {
      self.plan = decoded
      UserDefaults.standard.set(json, forKey: "coachPlan")
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let id = userInfo["ack"] as? String else { return }
    DispatchQueue.main.async {
      self.acked.insert(id)
      UserDefaults.standard.set(Array(self.acked), forKey: self.ackKey)
    }
  }
}
