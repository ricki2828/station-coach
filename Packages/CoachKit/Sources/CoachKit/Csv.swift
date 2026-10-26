import Foundation

public enum Clock {
  public static func epochMs(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

public enum Csv {
  /// Quotes a field only when it needs it (comma, quote, newline).
  public static func field(_ s: String) -> String {
    guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// One formatter per high-rate stream, so the files all agree with `FORMAT.md`.
public enum Lines {
  static func f(_ v: Double) -> String { String(format: "%.5f", v) }

  public static func accel(epochUs: Int64, x: Double, y: Double, z: Double) -> String {
    "\(epochUs),\(f(x)),\(f(y)),\(f(z))"
  }

  /// userAcceleration (g), rotationRate (rad/s), gravity (g).
  public static func motion(epochUs: Int64, ua: (Double, Double, Double), rr: (Double, Double, Double), g: (Double, Double, Double)) -> String {
    "\(epochUs),\(f(ua.0)),\(f(ua.1)),\(f(ua.2)),\(f(rr.0)),\(f(rr.1)),\(f(rr.2)),\(f(g.0)),\(f(g.1)),\(f(g.2))"
  }

  public static func hr(epochMs: Int64, bpm: Double) -> String { "\(epochMs),\(String(format: "%.0f", bpm))" }

  public static func battery(epochMs: Int64, level: Double, state: String) -> String {
    "\(epochMs),\(String(format: "%.2f", level)),\(state)"
  }

  public static func event(epochMs: Int64, kind: String, detail: String) -> String {
    "\(epochMs),\(Csv.field(kind)),\(Csv.field(detail))"
  }

  public static func rate(epochMs: Int64, stream: String, raw: RateMeter, stored: RateMeter) -> String {
    "\(epochMs),\(stream),\(raw.count),\(String(format: "%.1f", raw.hz ?? 0)),\(stored.count),\(String(format: "%.1f", stored.hz ?? 0))"
  }
}
