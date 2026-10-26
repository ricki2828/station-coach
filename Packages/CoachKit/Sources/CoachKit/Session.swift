import Foundation

public enum SessionFormat {
  public static let version = 1
}

public enum SessionStream: String, CaseIterable {
  case labels, cues, battery, hr, accel, motion, rates, events

  public var fileName: String { "\(rawValue).csv" }

  public var header: String {
    switch self {
    case .labels: return LabelEvent.csvHeader
    case .cues: return CueEvent.csvHeader
    case .battery: return "epoch_ms,level,state"
    case .hr: return "epoch_ms,bpm"
    case .accel: return "epoch_us,x,y,z"
    case .motion: return "epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z"
    case .rates: return "epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz"
    case .events: return "epoch_ms,kind,detail"
    }
  }
}

public struct SessionManifest: Codable, Equatable {
  public var formatVersion: Int
  public var sessionId: String
  public var startedAtEpochMs: Int64
  public var endedAtEpochMs: Int64?
  public var device: String
  public var osVersion: String
  public var appVersion: String
  public var workoutActivityType: String
  public var motionApi: String
  public var requestedHz: Double
  public var storeHz: Double
  public var cueIntervalSec: Int
  public var files: [String]?

  public init(
    sessionId: String, startedAtEpochMs: Int64, device: String, osVersion: String, appVersion: String,
    workoutActivityType: String, motionApi: String, requestedHz: Double, storeHz: Double, cueIntervalSec: Int
  ) {
    self.formatVersion = SessionFormat.version
    self.sessionId = sessionId
    self.startedAtEpochMs = startedAtEpochMs
    self.device = device
    self.osVersion = osVersion
    self.appVersion = appVersion
    self.workoutActivityType = workoutActivityType
    self.motionApi = motionApi
    self.requestedHz = requestedHz
    self.storeHz = storeHz
    self.cueIntervalSec = cueIntervalSec
  }
}

public struct SessionFile: Equatable {
  public let name: String
  public let bytes: Int
}

public struct SessionSummary: Identifiable, Equatable {
  public let id: String
  public let bytes: Int
  public let fileCount: Int
}

public enum SessionFiles {
  public static func list(_ folder: URL) throws -> [SessionFile] {
    let fm = FileManager.default
    return try fm.contentsOfDirectory(atPath: folder.path).sorted().compactMap { name in
      guard !name.hasPrefix(".") else { return nil }
      let attrs = try fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
      return SessionFile(name: name, bytes: (attrs[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  public static func summaries(in root: URL) -> [SessionSummary] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
    return names.sorted(by: >).compactMap { name in
      var isDir: ObjCBool = false
      let folder = root.appendingPathComponent(name)
      guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
            let files = try? list(folder) else { return nil }
      return SessionSummary(id: name, bytes: files.reduce(0) { $0 + $1.bytes }, fileCount: files.count)
    }
  }

  /// `<Documents>/Sessions`, created if missing.
  public static func defaultRoot() throws -> URL {
    let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let root = docs.appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// A session id and folder name: UTC start time plus a short random suffix.
  public static func makeSessionId(date: Date = Date(), suffix: String = String(UUID().uuidString.prefix(6)).lowercased()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: date) + "-" + suffix
  }
}

/// Append-only CSV writer. Appends are buffered on a private queue; `flush()` writes and fsyncs.
public final class AppendWriter {
  public let url: URL
  private let queue: DispatchQueue
  private var handle: FileHandle?
  private var buffer = Data()
  private var errorCount = 0
  private let autoFlushBytes = 32 * 1024

  public init(url: URL, header: String) throws {
    self.url = url
    self.queue = DispatchQueue(label: "coachkit.writer." + url.lastPathComponent)
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      guard fm.createFile(atPath: url.path, contents: Data((header + "\n").utf8)) else { throw CocoaError(.fileWriteUnknown) }
    }
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    self.handle = h
  }

  public func append(_ line: String) {
    queue.async {
      self.buffer.append(Data((line + "\n").utf8))
      if self.buffer.count >= self.autoFlushBytes { self.writeOut() }
    }
  }

  public func flush() {
    queue.sync {
      writeOut()
      try? handle?.synchronize()
    }
  }

  public func close() {
    queue.sync {
      writeOut()
      try? handle?.synchronize()
      try? handle?.close()
      handle = nil
    }
  }

  public var writeErrors: Int { queue.sync { errorCount } }

  private func writeOut() {
    guard let handle, !buffer.isEmpty else { return }
    do { try handle.write(contentsOf: buffer) } catch { errorCount += 1 }
    buffer.removeAll(keepingCapacity: true)
  }
}

/// One folder per session, one `AppendWriter` per stream, plus `manifest.json` (rewritten at finish).
public final class SessionWriter {
  public let folder: URL
  public private(set) var manifest: SessionManifest
  private var writers: [SessionStream: AppendWriter] = [:]

  public init(root: URL, manifest: SessionManifest) throws {
    self.manifest = manifest
    self.folder = root.appendingPathComponent(manifest.sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeManifest()
    for stream in SessionStream.allCases {
      writers[stream] = try AppendWriter(url: folder.appendingPathComponent(stream.fileName), header: stream.header)
    }
  }

  public func append(_ stream: SessionStream, _ line: String) { writers[stream]?.append(line) }

  public func flushAll() { writers.values.forEach { $0.flush() } }

  public var writeErrors: Int { writers.values.reduce(0) { $0 + $1.writeErrors } }

  public func finish(endedAtEpochMs: Int64, update: ((inout SessionManifest) -> Void)? = nil) throws {
    writers.values.forEach { $0.close() }
    manifest.endedAtEpochMs = endedAtEpochMs
    update?(&manifest)
    try writeManifest()
    manifest.files = try SessionFiles.list(folder).map(\.name)
    try writeManifest()
  }

  private func writeManifest() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
  }
}

/// Phone side: which files of which session have arrived intact. Codable so it survives relaunch.
public struct TransferTracker: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var total: Int
    var okFiles: [String: Bool]
  }

  private var sessions: [String: Entry] = [:]

  public init() {}

  public mutating func received(session: String, name: String, expectedBytes: Int, actualBytes: Int, total: Int) {
    var entry = sessions[session] ?? Entry(total: total, okFiles: [:])
    entry.total = total
    entry.okFiles[name] = expectedBytes == actualBytes
    sessions[session] = entry
  }

  public func isComplete(_ session: String) -> Bool {
    guard let e = sessions[session] else { return false }
    return e.okFiles.count >= e.total && e.okFiles.values.allSatisfy { $0 }
  }
}
