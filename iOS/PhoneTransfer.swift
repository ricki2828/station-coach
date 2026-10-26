import CoachKit
import Foundation
import WatchConnectivity

/// Receives session files from the watch into `Documents/Sessions/<id>/`, acks a session once every
/// file has arrived at its announced size, and lists what is on the phone.
final class PhoneTransfer: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = PhoneTransfer()

  @Published private(set) var sessions: [SessionSummary] = []
  @Published private(set) var completeIds: Set<String> = []

  private let trackerKey = "transferTracker"
  private var tracker: TransferTracker

  override init() {
    if let data = UserDefaults.standard.data(forKey: "transferTracker"),
       let t = try? JSONDecoder().decode(TransferTracker.self, from: data) {
      tracker = t
    } else {
      tracker = TransferTracker()
    }
    super.init()
    refresh()
  }

  static var root: URL? { try? SessionFiles.defaultRoot() }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func refresh() {
    guard let root = Self.root else { return }
    sessions = SessionFiles.summaries(in: root)
    completeIds = Set(sessions.map(\.id).filter { tracker.isComplete($0) })
  }

  func delete(_ id: String) {
    guard let root = Self.root else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
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

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { session.activate() }

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
      self.tracker.received(session: sid, name: name, expectedBytes: bytes, actualBytes: actual, total: total)
      if let data = try? JSONEncoder().encode(self.tracker) { UserDefaults.standard.set(data, forKey: self.trackerKey) }
      if self.tracker.isComplete(sid) { WCSession.default.transferUserInfo(["ack": sid]) }
      self.refresh()
    }
  }
}
