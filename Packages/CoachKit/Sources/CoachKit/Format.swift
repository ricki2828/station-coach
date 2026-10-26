import Foundation

/// Time strings used on screen and in cues. Delta convention: positive = behind plan (amber), negative = ahead.
public enum Fmt {
  /// "5:05", or "1:18:42" from an hour up.
  public static func clock(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// "0:32" with no sign, for gaps ("1:18 under target").
  public static func gap(_ seconds: Int) -> String {
    let s = abs(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// "+0:32" when behind plan, "\u{2212}0:20" when ahead, "0:00" when level.
  public static func delta(_ seconds: Int) -> String {
    if seconds == 0 { return "0:00" }
    return (seconds > 0 ? "+" : "\u{2212}") + gap(seconds)
  }

  /// "1h 20m" style for a target.
  public static func target(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds / 60) % 60
    return h > 0 ? String(format: "%d:%02d:00", h, m) : String(format: "%d:00", m)
  }

  private static let words: [Int: String] = [
    5: "five", 10: "ten", 15: "fifteen", 20: "twenty", 25: "twenty-five", 30: "thirty",
    35: "thirty-five", 40: "forty", 45: "forty-five", 50: "fifty", 55: "fifty-five",
  ]

  /// A number as speech reads best: "fifteen" for the multiples of five up to 55, digits otherwise.
  public static func word(_ n: Int) -> String { words[n] ?? "\(n)" }

  /// Seconds as a short spoken phrase: "thirty seconds", "1 minute 10", "2 minutes".
  public static func spoken(_ seconds: Int) -> String {
    let s = abs(seconds)
    if s < 60 { return "\(word(s)) seconds" }
    let m = s / 60, r = s % 60
    let minutes = m == 1 ? "1 minute" : "\(m) minutes"
    return r == 0 ? minutes : "\(minutes) \(r)"
  }
}
