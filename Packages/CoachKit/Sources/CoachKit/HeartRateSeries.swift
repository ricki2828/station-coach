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
            let b = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
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

  /// The highest rolling mean over `windowMs` (default 10 s), needing `minSamples` inside the window. nil if none.
  public func peakAverage(windowMs: Int64 = 10_000, minSamples: Int = 3) -> Int? {
    var best: Double?
    var lo = 0
    var sum = 0
    for hi in samples.indices {
      sum += samples[hi].bpm
      while samples[hi].epochMs - samples[lo].epochMs >= windowMs {
        sum -= samples[lo].bpm
        lo += 1
      }
      let n = hi - lo + 1
      if n >= minSamples {
        let mean = Double(sum) / Double(n)
        if best == nil || mean > best! { best = mean }
      }
    }
    return best.map { Int($0.rounded()) }
  }
}
