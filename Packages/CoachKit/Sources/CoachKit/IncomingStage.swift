import Foundation

/// What the phone needs to apply one incoming session file: the session folder, the file name, and the sizes the watch announced.
public struct IncomingEntry: Codable, Equatable {
  public var sid: String
  public var name: String
  public var bytes: Int
  public var total: Int

  public init(sid: String, name: String, bytes: Int, total: Int) {
    self.sid = sid
    self.name = name
    self.bytes = bytes
    self.total = total
  }
}

/// Durable staging for incoming files that cannot be applied yet (a zip is being built). The metadata is in the file name, so
/// a file left behind by a kill can be applied on the next launch, in arrival order, with nothing else to read.
/// Name: `<12-digit sequence>-<base64url of the entry's JSON>`.
public enum IncomingStage {
  public static func fileName(seq: Int, entry: IncomingEntry) -> String {
    let json = (try? JSONEncoder().encode(entry)) ?? Data()
    let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return String(format: "%012d-", seq) + b64
  }

  public static func parse(fileName: String) -> (seq: Int, entry: IncomingEntry)? {
    let parts = fileName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 12, let seq = Int(parts[0]) else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64), let entry = try? JSONDecoder().decode(IncomingEntry.self, from: data) else { return nil }
    return (seq, entry)
  }

  /// Moves `file` into `dir` (created if missing) under its metadata name. Returns the new URL.
  @discardableResult
  public static func stage(_ file: URL, entry: IncomingEntry, seq: Int, into dir: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(fileName(seq: seq, entry: entry))
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: file, to: dest)
    return dest
  }

  /// Everything staged in `dir`, oldest first. Names that do not parse are ignored.
  public static func pending(in dir: URL) -> [(url: URL, entry: IncomingEntry)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.compactMap { n in parse(fileName: n).map { (seq: $0.seq, url: dir.appendingPathComponent(n), entry: $0.entry) } }
      .sorted { $0.seq < $1.seq }
      .map { (url: $0.url, entry: $0.entry) }
  }

  /// Removes `incoming-*` files in `tmp`: the phone stages a file there for one main-queue hop, so any left at launch are orphans.
  /// Call before the phone starts receiving.
  @discardableResult
  public static func sweepOrphans(inTemp tmp: URL) -> Int {
    let fm = FileManager.default
    var n = 0
    for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("incoming-") {
      if (try? fm.removeItem(at: tmp.appendingPathComponent(name))) != nil { n += 1 }
    }
    return n
  }
}
