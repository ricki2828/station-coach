import CoachKit
import CoreMotion
import Foundation

/// Records accelerometer and device motion at the highest rate the watch offers, stores them at
/// <= `storeHz`, and keeps raw and stored rate meters so the achieved rate is logged every minute.
/// `CMBatchedSensorManager` (watchOS 10, needs a running workout session) when supported; otherwise
/// `CMMotionManager` asked for 100 Hz.
final class MotionRecorder {
  static let legacyHz = 100.0

  static var batchedSupported: Bool {
    CMBatchedSensorManager.isAccelerometerSupported && CMBatchedSensorManager.isDeviceMotionSupported
  }

  /// "CMBatchedSensorManager" or "CMMotionManager"; changes if the batched stream fails and we fall back.
  private(set) var api: String
  /// What we ask the hardware for, for the manifest (batched: nominal 800 accel / 200 motion).
  var requestedHz: Double { api == "CMBatchedSensorManager" ? 800 : Self.legacyHz }
  var onEvent: ((String, String) -> Void)?

  private let batched = CMBatchedSensorManager()
  private let legacy = CMMotionManager()
  private var tasks: [Task<Void, Never>] = []
  private let bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
  private let lock = NSLock()
  private var writer: SessionWriter?
  private var legacyRunning = false

  private var accelRaw = RateMeter(), accelStored = RateMeter()
  private var motionRaw = RateMeter(), motionStored = RateMeter()
  private var accelDec: Decimator
  private var motionDec: Decimator
  let storeHz: Double
  private var lastRawHz: Double?
  private var totalRaw = 0
  private var startedAt: Date?
  private var firstSampleAt: Date?

  init(storeHz: Double) {
    self.storeHz = storeHz
    accelDec = Decimator(targetHz: storeHz)
    motionDec = Decimator(targetHz: storeHz)
    api = Self.batchedSupported ? "CMBatchedSensorManager" : "CMMotionManager"
  }

  func start(writer: SessionWriter) {
    self.writer = writer
    lock.lock()
    startedAt = Date()
    lock.unlock()
    if Self.batchedSupported {
      onEvent?("motion_api", "CMBatchedSensorManager accel=\(batched.accelerometerDataFrequency)Hz motion=\(batched.deviceMotionDataFrequency)Hz")
      tasks.append(Task { [weak self] in await self?.runBatchedAccel() })
      tasks.append(Task { [weak self] in await self?.runBatchedMotion() })
    } else {
      onEvent?("motion_api", "CMMotionManager (batched unsupported)")
      startLegacy()
    }
  }

  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
    batched.stopAccelerometerUpdates()
    batched.stopDeviceMotionUpdates()
    legacy.stopAccelerometerUpdates()
    legacy.stopDeviceMotionUpdates()
    writer = nil
  }

  /// Appends one `rates.csv` row per stream for the window since the last call, then starts a new window.
  func writeRates(atMs ms: Int64) {
    lock.lock()
    let rows = [
      Lines.rate(epochMs: ms, stream: "accel", raw: accelRaw, stored: accelStored),
      Lines.rate(epochMs: ms, stream: "motion", raw: motionRaw, stored: motionStored),
    ]
    lastRawHz = accelRaw.hz ?? motionRaw.hz ?? lastRawHz
    accelRaw.reset(); accelStored.reset(); motionRaw.reset(); motionStored.reset()
    lock.unlock()
    rows.forEach { writer?.append(.rates, $0) }
  }

  /// Raw samples delivered since start, both streams; the watchdog checks it keeps growing.
  var totalRawSamples: Int {
    lock.lock(); defer { lock.unlock() }
    return totalRaw
  }

  /// Seconds from `start` to the first delivered sample; nil until one arrives.
  var firstSampleDelay: TimeInterval? {
    lock.lock(); defer { lock.unlock() }
    guard let startedAt, let firstSampleAt else { return nil }
    return firstSampleAt.timeIntervalSince(startedAt)
  }

  var latestRawHz: Double? {
    lock.lock(); defer { lock.unlock() }
    return lastRawHz
  }

  // MARK: Batched

  private func runBatchedAccel() async {
    do {
      for try await batch in batched.accelerometerUpdates() {
        accel(batch: batch.map { ($0.timestamp, $0.acceleration.x, $0.acceleration.y, $0.acceleration.z) })
      }
    } catch {
      onEvent?("accel_stream_error", "\(error)")
      fallBackToLegacy()
    }
  }

  private func runBatchedMotion() async {
    do {
      for try await batch in batched.deviceMotionUpdates() {
        motion(batch: batch)
      }
    } catch {
      onEvent?("motion_stream_error", "\(error)")
      fallBackToLegacy()
    }
  }

  private func fallBackToLegacy() {
    lock.lock()
    let already = legacyRunning
    lock.unlock()
    guard !already, !Task.isCancelled else { return }
    api = "CMMotionManager"
    onEvent?("motion_api", "fell back to CMMotionManager")
    startLegacy()
  }

  // MARK: Legacy

  private func startLegacy() {
    lock.lock()
    legacyRunning = true
    lock.unlock()
    let interval = 1.0 / Self.legacyHz
    legacy.accelerometerUpdateInterval = interval
    legacy.deviceMotionUpdateInterval = interval
    if legacy.isAccelerometerAvailable {
      let q = OperationQueue()
      q.maxConcurrentOperationCount = 1
      legacy.startAccelerometerUpdates(to: q) { [weak self] data, _ in
        guard let d = data else { return }
        self?.accel(batch: [(d.timestamp, d.acceleration.x, d.acceleration.y, d.acceleration.z)])
      }
    }
    if legacy.isDeviceMotionAvailable {
      let q = OperationQueue()
      q.maxConcurrentOperationCount = 1
      legacy.startDeviceMotionUpdates(to: q) { [weak self] data, _ in
        guard let d = data else { return }
        self?.motion(batch: [d])
      }
    }
  }

  // MARK: Samples

  private func accel(batch: [(Double, Double, Double, Double)]) {
    lock.lock(); defer { lock.unlock() }
    var lines: [String] = []
    totalRaw += batch.count
    if firstSampleAt == nil, !batch.isEmpty { firstSampleAt = Date() }
    for (t, x, y, z) in batch {
      accelRaw.add(t)
      guard accelDec.keep(t) else { continue }
      accelStored.add(t)
      lines.append(Lines.accel(epochUs: epochUs(t), x: x, y: y, z: z))
    }
    writer?.append(.accel, lines: lines)
  }

  private func motion(batch: [CMDeviceMotion]) {
    lock.lock(); defer { lock.unlock() }
    var lines: [String] = []
    totalRaw += batch.count
    if firstSampleAt == nil, !batch.isEmpty { firstSampleAt = Date() }
    for d in batch {
      motionRaw.add(d.timestamp)
      guard motionDec.keep(d.timestamp) else { continue }
      motionStored.add(d.timestamp)
      lines.append(Lines.motion(
        epochUs: epochUs(d.timestamp),
        ua: (d.userAcceleration.x, d.userAcceleration.y, d.userAcceleration.z),
        rr: (d.rotationRate.x, d.rotationRate.y, d.rotationRate.z),
        g: (d.gravity.x, d.gravity.y, d.gravity.z)))
    }
    writer?.append(.motion, lines: lines)
  }

  private func epochUs(_ bootSeconds: Double) -> Int64 { Int64((bootSeconds + bootOffset) * 1_000_000) }
}
