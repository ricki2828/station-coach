import CoachKit
import Foundation
import SwiftUI
import WatchKit

@MainActor
final class RecorderController: ObservableObject {
  enum Phase { case idle, starting, running, finishing }

  @Published var phase: Phase = .idle
  @Published var currentLabel: Activity?
  @Published var startedAt = Date()
  @Published var heartRate: Int?
  @Published var batteryPercent: Int?
  @Published var lastCue = "-"
  @Published var cueCount = 0
  @Published var motionApi = "-"
  @Published var rawHz: Int?
  @Published var statusMessage: String?
  @Published var storeHz: Int {
    didSet { UserDefaults.standard.set(storeHz, forKey: "storeHz") }
  }
  @Published var cueInterval: Int {
    didSet { UserDefaults.standard.set(cueInterval, forKey: "cueInterval") }
  }

  private let workout = WorkoutService()
  private var motion: MotionRecorder?
  private let cues = CueRunner()
  private var writer: SessionWriter?
  private var labelLog = LabelLog()
  private var minuteTimer: Timer?

  init() {
    let saved = UserDefaults.standard.integer(forKey: "cueInterval")
    cueInterval = saved > 0 ? saved : 45
    let hz = UserDefaults.standard.integer(forKey: "storeHz")
    storeHz = hz > 0 ? hz : 100
  }

  func start() async {
    guard phase == .idle else { return }
    phase = .starting
    statusMessage = nil
    do {
      try await workout.requestAuthorization()
      let device = WKInterfaceDevice.current()
      device.isBatteryMonitoringEnabled = true

      let motion = MotionRecorder(storeHz: Double(storeHz))
      let started = Date()
      let manifest = SessionManifest(
        sessionId: SessionFiles.makeSessionId(date: started),
        startedAtEpochMs: Clock.epochMs(started),
        device: device.model + " " + device.name,
        osVersion: device.systemName + " " + device.systemVersion,
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
        workoutActivityType: "crossTraining",
        motionApi: motion.api,
        requestedHz: motion.requestedHz,
        storeHz: motion.storeHz,
        cueIntervalSec: cueInterval)
      let writer = try SessionWriter(root: SessionFiles.defaultRoot(), manifest: manifest)
      self.writer = writer
      self.motion = motion
      labelLog = LabelLog()
      currentLabel = nil
      cueCount = 0
      lastCue = "-"
      startedAt = started
      WatchTransfer.shared.activeSessionId = manifest.sessionId

      wire(writer: writer, motion: motion)
      log("session_start", manifest.sessionId)
      try await workout.start()
      motion.start(writer: writer)
      motionApi = motion.api
      cues.start(interval: TimeInterval(cueInterval))
      minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.minuteTick() }
      }
      minuteTick()
      phase = .running
    } catch {
      statusMessage = "Could not start: \(error.localizedDescription)"
      writer?.flushAll()
      writer = nil
      motion = nil
      WatchTransfer.shared.activeSessionId = nil
      phase = .idle
    }
  }

  func stop() async {
    guard phase == .running, let writer else { return }
    phase = .finishing
    minuteTimer?.invalidate()
    minuteTimer = nil
    cues.stop()
    motion?.writeRates(atMs: Clock.epochMs())
    motion?.stop()
    await workout.stop()
    log("session_end", "write_errors=\(writer.writeErrors)")
    do {
      let api = motion?.api ?? "?"
      try writer.finish(endedAtEpochMs: Clock.epochMs()) { $0.motionApi = api }
    } catch {
      statusMessage = "Finish failed: \(error.localizedDescription)"
    }
    let id = writer.manifest.sessionId
    self.writer = nil
    motion = nil
    WatchTransfer.shared.activeSessionId = nil
    WatchTransfer.shared.sendUnsent()
    statusMessage = "Saved \(id)"
    phase = .idle
  }

  func tap(_ activity: Activity) {
    guard phase == .running, let writer else { return }
    if let e = labelLog.set(activity, at: Clock.epochMs()) {
      writer.append(.labels, e.csvLine)
      currentLabel = labelLog.current
      WKInterfaceDevice.current().play(.click)
    }
  }

  func undo() {
    guard phase == .running, let writer else { return }
    if let e = labelLog.undo(at: Clock.epochMs()) {
      writer.append(.labels, e.csvLine)
      currentLabel = labelLog.current
      WKInterfaceDevice.current().play(.retry)
    }
  }

  func flagMissedCue() { cues.markLastMissed() }

  // MARK: Wiring

  private func wire(writer: SessionWriter, motion: MotionRecorder) {
    workout.onHeartRate = { [weak self] bpm in
      writer.append(.hr, Lines.hr(epochMs: Clock.epochMs(), bpm: bpm))
      Task { @MainActor in self?.heartRate = Int(bpm.rounded()) }
    }
    workout.onEvent = { kind, detail in writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail)) }
    motion.onEvent = { [weak self] kind, detail in
      writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail))
      Task { @MainActor in if let m = self?.motion { self?.motionApi = m.api } }
    }
    cues.onCue = { [weak self] event in
      writer.append(.cues, event.csvLine)
      if event.kind == .issued { Task { @MainActor in self?.cueCount += 1 } }
    }
    cues.onNote = { kind, detail in writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail)) }
    cues.onIssued = { [weak self] phrase in self?.lastCue = phrase }
  }

  private func log(_ kind: String, _ detail: String) {
    writer?.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail))
  }

  private func minuteTick() {
    guard let writer else { return }
    let now = Clock.epochMs()
    let device = WKInterfaceDevice.current()
    let level = Double(device.batteryLevel)
    writer.append(.battery, Lines.battery(epochMs: now, level: level, state: Self.batteryState(device.batteryState)))
    batteryPercent = level >= 0 ? Int((level * 100).rounded()) : nil
    motion?.writeRates(atMs: now)
    if let hz = motion?.latestRawHz { rawHz = Int(hz.rounded()) }
    writer.flushAll()
  }

  private static func batteryState(_ s: WKInterfaceDeviceBatteryState) -> String {
    switch s {
    case .unknown: return "unknown"
    case .unplugged: return "unplugged"
    case .charging: return "charging"
    case .full: return "full"
    @unknown default: return "unknown"
    }
  }
}
