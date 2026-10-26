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
  @Published var missedTaps = 0
  @Published var motionApi = "-"
  @Published var rawHz: Int?
  @Published var statusMessage: String?
  /// Set when recording is no longer trustworthy (workout ended, motion stream died). Cleared by `dismissAlarm`.
  @Published var alarm: String?
  /// Short-lived message such as "Headphones lost, vibrating instead".
  @Published var toast: String?
  /// Set by the coach: fed (epoch s, magnitude g) for each stored motion sample.
  var onMotionMagnitude: ((Double, Double) -> Void)?
  private var coachMode = false
  var sessionFolder: URL? { writer?.folder }
  @Published var unfinished: [String] = []
  @Published var storeHz: Int {
    didSet { UserDefaults.standard.set(storeHz, forKey: "storeHz") }
  }
  @Published var audioMode: AudioMode {
    didSet { UserDefaults.standard.set(audioMode.rawValue, forKey: "audioMode") }
  }
  /// Athlete code (A1, A2, A3: never a name) and wrist side, stored in the manifest.
  @Published var athlete: String {
    didSet { UserDefaults.standard.set(athlete, forKey: "athlete") }
  }
  @Published var wrist: String {
    didSet { UserDefaults.standard.set(wrist, forKey: "wrist") }
  }
  static let athleteCodes = ["A1", "A2", "A3", "A4"]
  @Published var cueInterval: Int {
    didSet { UserDefaults.standard.set(cueInterval, forKey: "cueInterval") }
  }

  private let workout = WorkoutService()
  private var motion: MotionRecorder?
  let cues = CueRunner()
  private var writer: SessionWriter?
  private var labelLog = LabelLog()
  private var minuteTimer: Timer?
  private var alarmTimer: Timer?
  private var watchdogTimer: Timer?
  private var watchdogTotal = 0
  private var watchdogSince = Date()
  static let stallSeconds: TimeInterval = 30
  /// Time allowed for the first motion sample (the batched stream can start slowly).
  static let startGraceSeconds: TimeInterval = 90
  private var sawFirstSample = false

  init() {
    let saved = UserDefaults.standard.integer(forKey: "cueInterval")
    cueInterval = saved > 0 ? saved : 45
    let hz = UserDefaults.standard.integer(forKey: "storeHz")
    storeHz = hz > 0 ? hz : 100
    audioMode = AudioMode(rawValue: UserDefaults.standard.string(forKey: "audioMode") ?? "") ?? .shortForm
    athlete = UserDefaults.standard.string(forKey: "athlete") ?? Self.athleteCodes[0]
    wrist = UserDefaults.standard.string(forKey: "wrist") ?? "left"
    refreshUnfinished()
  }

  func start(coach: Bool = false, transitionSeconds: Int? = nil) async {
    guard phase == .idle else { return }
    coachMode = coach
    phase = .starting
    statusMessage = nil
    do {
      // A declined heart-rate permission must not stop the session: the coach still works.
      try? await workout.requestAuthorization()
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
        cueIntervalSec: coach ? 0 : cueInterval,
        audioMode: audioMode.rawValue,
        athlete: athlete,
        wrist: wrist,
        labelSource: coach ? "coach" : "athlete_taps",
        transitionLabelSeconds: coach ? transitionSeconds : nil)
      let writer = try SessionWriter(root: SessionFiles.defaultRoot(), manifest: manifest)
      self.writer = writer
      self.motion = motion
      labelLog = LabelLog()
      currentLabel = nil
      cueCount = 0
      missedTaps = 0
      lastCue = "-"
      startedAt = started
      WatchTransfer.shared.activeSessionId = manifest.sessionId
      WatchTransfer.shared.pauseForRecording()

      wire(writer: writer, motion: motion)
      log("session_start", manifest.sessionId)
      await workout.endOrphanedSession()
      try await workout.start()
      motion.onMagnitude = { [weak self] t, m in self?.onMotionMagnitude?(t, m) }
      motion.start(writer: writer)
      motionApi = motion.api
      cues.audioMode = audioMode
      await cues.prepare()
      if !coach { cues.start(interval: TimeInterval(cueInterval)) }
      minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.minuteTick() }
      }
      watchdogTotal = 0
      sawFirstSample = false
      watchdogSince = Date()
      watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.watchdogTick() }
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
    dismissAlarm()
    minuteTimer?.invalidate()
    minuteTimer = nil
    watchdogTimer?.invalidate()
    watchdogTimer = nil
    cues.stop(letSpeechFinish: coachMode)
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
    refreshUnfinished()
    phase = .idle
  }

  func tap(_ activity: Activity, haptic: Bool = true) {
    guard phase == .running, let writer else { return }
    if let e = labelLog.set(activity, at: Clock.epochMs()) {
      writer.append(.labels, e.csvLine)
      currentLabel = labelLog.current
      if haptic { WKInterfaceDevice.current().play(.click) }
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

  func refreshUnfinished() {
    guard let root = try? SessionFiles.defaultRoot() else { return }
    unfinished = SessionFiles.unfinished(in: root)
  }

  /// Keeps the data of sessions the app lost, closes them, and queues them for transfer.
  func keepUnfinished() {
    guard let root = try? SessionFiles.defaultRoot() else { return }
    for id in unfinished { try? SessionFiles.closeUnfinished(in: root, id: id) }
    refreshUnfinished()
    WatchTransfer.shared.sendUnsent()
  }

  func dismissAlarm() {
    alarm = nil
    alarmTimer?.invalidate()
    alarmTimer = nil
  }

  private func raiseAlarm(_ message: String) {
    guard phase == .running else { return }
    log("alarm", message)
    guard alarm == nil else { return }
    alarm = message
    WKInterfaceDevice.current().play(.failure)
    alarmTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in WKInterfaceDevice.current().play(.failure) }
  }

  func flagMissedCue() {
    if cues.markLastMissed() {
      missedTaps += 1
      WKInterfaceDevice.current().play(.click)
    } else {
      WKInterfaceDevice.current().play(.failure) // nothing recent to flag
    }
  }

  // MARK: Wiring

  private func wire(writer: SessionWriter, motion: MotionRecorder) {
    workout.onHeartRate = { [weak self] bpm in
      writer.append(.hr, Lines.hr(epochMs: Clock.epochMs(), bpm: bpm))
      Task { @MainActor in self?.heartRate = Int(bpm.rounded()) }
    }
    workout.onUnexpectedEnd = { [weak self] message in Task { @MainActor in self?.raiseAlarm(message) } }
    workout.onEvent = { kind, detail in writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail)) }
    motion.onEvent = { [weak self] kind, detail in
      writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail))
      Task { @MainActor in
        if let m = self?.motion { self?.motionApi = m.api }
        if kind.hasSuffix("stream_error") { self?.raiseAlarm("Motion stream failed") }
      }
    }
    cues.onCue = { [weak self] event in
      writer.append(.cues, event.csvLine)
      if event.kind == .issued { Task { @MainActor in self?.cueCount += 1 } }
    }
    cues.onHeadphonesLost = { [weak self] in
      Task { @MainActor in
        self?.toast = "Headphones lost, vibrating instead"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        self?.toast = nil
      }
    }
    cues.onNote = { kind, detail in writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail)) }
    cues.onIssued = { [weak self] phrase in self?.lastCue = phrase }
  }

  private func log(_ kind: String, _ detail: String) {
    writer?.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: kind, detail: detail))
  }

  /// Alarms if no motion sample arrives within `startGraceSeconds` of the start, then if both streams
  /// deliver nothing for `stallSeconds`: alive but silent.
  private func watchdogTick() {
    guard phase == .running, let motion else { return }
    let total = motion.totalRawSamples
    if !sawFirstSample {
      if total > 0 {
        sawFirstSample = true
        watchdogTotal = total
        watchdogSince = Date()
        log("first_motion_sample", String(format: "delay=%.1fs", motion.firstSampleDelay ?? -1))
      } else if Date().timeIntervalSince(watchdogSince) >= Self.startGraceSeconds {
        raiseAlarm("Motion never started")
      }
      return
    }
    if total != watchdogTotal {
      watchdogTotal = total
      watchdogSince = Date()
    } else if Date().timeIntervalSince(watchdogSince) >= Self.stallSeconds {
      raiseAlarm("No motion samples for \(Int(Self.stallSeconds)) s")
    }
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
