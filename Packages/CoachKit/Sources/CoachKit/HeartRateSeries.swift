import Foundation

public struct HeartRateSample: Equatable {
  public let epochMs: Int64
  public let bpm: Int

  public init(epochMs: Int64, bpm: Int) {
    self.epochMs = epochMs
    self.bpm = bpm
  }
}

/// A stretch of time one heart-rate sample speaks for.
public struct HeartRateInterval: Equatable {
  public let startMs: Int64
  public let endMs: Int64
  public let bpm: Int
}

/// A session's `hr.csv` (`epoch_ms,bpm`): cleaned samples, plus what they cover and how hard.
/// A sample covers up to 10 s after it (or until the next sample); a longer gap is uncovered.
public struct HeartRateSeries: Equatable {
  public static let coverMs: Int64 = 10_000
  public static let maxPlausibleBpm = 220
  public static let minPlausibleBpm = 30
  /// A jump bigger than this within `spikeWindowMs` of the last kept sample is a wrist-sensor spike and is dropped.
  public static let spikeBpm = 40
  public static let spikeWindowMs: Int64 = 2_000

  public let samples: [HeartRateSample]

  /// Sorts, drops implausible values (over 220, under 30) and spikes.
  public init(samples raw: [HeartRateSample]) {
    var kept: [HeartRateSample] = []
    for s in raw.sorted(by: { $0.epochMs < $1.epochMs }) {
      guard s.bpm >= Self.minPlausibleBpm, s.bpm <= Self.maxPlausibleBpm else { continue }
      if let last = kept.last, s.epochMs - last.epochMs <= Self.spikeWindowMs, abs(s.bpm - last.bpm) > Self.spikeBpm { continue }
      kept.append(s)
    }
    samples = kept
  }

  /// Reads `epoch_ms,bpm` lines. A header, blank or malformed line is skipped.
  public static func parse(csv: String) -> HeartRateSeries {
    var out: [HeartRateSample] = []
    for line in csv.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ",", omittingEmptySubsequences: false)
      guard parts.count >= 2,
            let t = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
            let b = Double(parts[1].trimmingCharacters(in: .whitespaces)), b.isFinite else { continue }
      out.append(HeartRateSample(epochMs: t, bpm: Int(b.rounded())))
    }
    return HeartRateSeries(samples: out)
  }

  public var isEmpty: Bool { samples.isEmpty }

  /// Covered stretches clipped to `from..<to`, in time order, never overlapping.
  public func intervals(from: Int64, to: Int64) -> [HeartRateInterval] {
    guard to > from else { return [] }
    var out: [HeartRateInterval] = []
    for (i, s) in samples.enumerated() {
      var end = s.epochMs + Self.coverMs
      if i + 1 < samples.count { end = min(end, samples[i + 1].epochMs) }
      let a = max(s.epochMs, from), b = min(end, to)
      if b > a { out.append(HeartRateInterval(startMs: a, endMs: b, bpm: s.bpm)) }
    }
    return out
  }

  public func coveredMs(from: Int64, to: Int64) -> Int64 {
    intervals(from: from, to: to).reduce(0) { $0 + ($1.endMs - $1.startMs) }
  }

  /// Share of `from..<to` that has a heart-rate sample behind it, 0...1.
  public func coverage(from: Int64, to: Int64) -> Double {
    guard to > from else { return 0 }
    return Double(coveredMs(from: from, to: to)) / Double(to - from)
  }

  /// Seconds spent in zones 1...5 (index 0 is zone 1) against `maxHR`.
  public func zoneSeconds(maxHR: Int, from: Int64, to: Int64) -> [Double] {
    var z = [Double](repeating: 0, count: 5)
    for iv in intervals(from: from, to: to) {
      z[Palette.zone(bpm: iv.bpm, maxHR: maxHR) - 1] += Double(iv.endMs - iv.startMs) / 1000
    }
    return z
  }

  /// A rolling median of 3 over the bpm, which removes a lone artefact reading (a spike at a 5 s cadence is one sample).
  public func smoothed() -> [HeartRateSample] {
    guard samples.count >= 3 else { return samples }
    return samples.indices.map { i in
      let lo = max(0, i - 1), hi = min(samples.count - 1, i + 1)
      let m = samples[lo...hi].map(\.bpm).sorted()
      return HeartRateSample(epochMs: samples[i].epochMs, bpm: m[m.count / 2])
    }
  }

  /// The highest mean heart rate over a time window (default 30 s), after median smoothing. The window must hold at least
  /// `minSamples` samples spanning at least `minSpanMs`, so it works at the watch's 5 s cadence as well as 1 Hz. nil if none.
  public func peakAverage(windowMs: Int64 = 30_000, minSpanMs: Int64 = 20_000, minSamples: Int = 3) -> Int? {
    let s = smoothed()
    var best: Double?
    var lo = 0
    var sum = 0
    for hi in s.indices {
      sum += s[hi].bpm
      while s[hi].epochMs - s[lo].epochMs >= windowMs {
        sum -= s[lo].bpm
        lo += 1
      }
      let n = hi - lo + 1
      if n >= minSamples, s[hi].epochMs - s[lo].epochMs >= minSpanMs {
        let mean = Double(sum) / Double(n)
        if best == nil || mean > best! { best = mean }
      }
    }
    return best.map { Int($0.rounded()) }
  }

  /// Reads a session's `hr.csv`. nil when the file is missing; an unreadable one is logged and also gives nil.
  public static func load(url: URL) -> HeartRateSeries? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return parse(csv: try String(contentsOf: url, encoding: .utf8))
    } catch {
      NSLog("HeartRateSeries: cannot read %@: %@", url.path, String(describing: error))
      return nil
    }
  }
}
