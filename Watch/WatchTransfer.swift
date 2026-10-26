import CoachKit
import Foundation
import WatchConnectivity

/// Sends finished session folders to the phone, one `transferFile` per file, and keeps them on
/// the watch until the phone answers with an ack for that session id.
final class WatchTransfer: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WatchTransfer()

  @Published private(set) var acked: Set<String>
  /// The folder being recorded right now; never sent.
  var activeSessionId: String?

  private let ackKey = "ackedSessions"

  override init() {
    acked = Set(UserDefaults.standard.stringArray(forKey: "ackedSessions") ?? [])
    super.init()
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  /// Queues every finished, un-acked session. Safe to call repeatedly: files already queued are skipped.
  func sendUnsent() {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated,
          let root = try? SessionFiles.defaultRoot() else { return }
    let queued = Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL })
    for summary in SessionFiles.summaries(in: root) where summary.id != activeSessionId && !acked.contains(summary.id) {
      let folder = root.appendingPathComponent(summary.id)
      guard let files = try? SessionFiles.list(folder) else { continue }
      for f in files {
        let url = folder.appendingPathComponent(f.name)
        if queued.contains(url) { continue }
        WCSession.default.transferFile(url, metadata: ["session": summary.id, "name": f.name, "bytes": f.bytes, "total": files.count])
      }
    }
  }

  func deleteAcked() {
    guard let root = try? SessionFiles.defaultRoot() else { return }
    for id in acked { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
    objectWillChange.send()
  }

  func isAcked(_ id: String) -> Bool { acked.contains(id) }

  // MARK: WCSessionDelegate

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    if activationState == .activated { sendUnsent() }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let id = userInfo["ack"] as? String else { return }
    DispatchQueue.main.async {
      self.acked.insert(id)
      UserDefaults.standard.set(Array(self.acked), forKey: self.ackKey)
    }
  }
}
