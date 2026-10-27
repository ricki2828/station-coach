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
  /// No heart-rate samples when there should be some (read declined, band loose). The session carries on.
  @Published var hrOff = false
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
  private var hrWatch = HeartRateWatch()
  private var clock: TimeInterval { Date().timeIntervalSinceReferenceDate }
  static let hrMissedKey = "hrMissedLastSession"
  private var minuteTimer: Timer?
  private var alarmTimer: Timer?
  /// Once the athlete taps OK, the same fault does not come back as a full-screen alarm (see AlarmGate).
  private var alarmGate = AlarmGate()
  private var watchdogTimer: Timer?
  private var watchdogTotal = 0
  private var watchdogSince = Date()
  static let stallSeconds: TimeInterval = 30
  /// Time allowed for the first motion sample (the batched stream can start slowly).
  static let startGraceSeconds: TimeInterval = 90
  private var sawFirstSample = false
  private var thermalObserver: NSObjectProtocol?

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

  /// The wrist the watch says it is on; the stored setting if it cannot tell.
  private static func worn(fallback: String) -> String {
    switch WKInterfaceDevice.current().wristLocation {
    case .left: return "left"
    case .right: return "right"
    @unknown default: return fallback
    }
  }

  private static func crown() -> String? {
    switch WKInterfaceDevice.current().crownOrientation {
    case .left: return "left"
    case .right: return "right"
    @unknown default: return nil
    }
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
        // Coached sessions have no wrist picker: take the real wrist from the watch. Recorder-only keeps its setting.
        wrist: coach ? Self.worn(fallback: wrist) : wrist,
        crownOrientation: Self.crown(),
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
      await beginRuntime(writer: writer, motion: motion, coach: coach)
    } catch {
      statusMessage = "Could not start: \(error.localizedDescription)"
      writer?.flushAll()
      writer = nil
      motion = nil
      WatchTransfer.shared.activeSessionId = nil
      phase = .idle
    }
  }

  /// Everything after the workout session is up: heart rate, motion, cues, the timers. Shared by a fresh start and a resume.
  private func beginRuntime(writer: SessionWriter, motion: MotionRecorder, coach: Bool) async {
    alarmGate.reset()
    hrWatch.start(at: clock)
    hrOff = false
    heartRate = nil
    motion.onMagnitude = { [weak self] t, m in self?.onMotionMagnitude?(t, m) }
    motion.start(writer: writer)
    motionApi = motion.api
    cues.audioMode = audioMode
    await cues.prepare()
    if cues.headphones == false { flash("No headphones: cues by vibration") }
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
    startThermalLog()
    phase = .running
  }

  /// Picks up an unfinished coached session after the app was killed: appends to its files, reattaches the system workout
  /// session and carries on. False (and the folder untouched) if any of that fails; the caller then closes the folder.
  func resume(folder: URL) async -> Bool {
    guard phase == .idle else { return false }
    coachMode = true
    phase = .starting
    statusMessage = nil
    do {
      let writer = try SessionWriter(resuming: folder)
      let motion = MotionRecorder(storeHz: writer.manifest.storeHz)
      self.writer = writer
      self.motion = motion
      labelLog = LabelLog()
      currentLabel = nil
      cueCount = 0
      missedTaps = 0
      lastCue = "-"
      startedAt = Date(timeIntervalSince1970: Double(writer.manifest.startedAtEpochMs) / 1000)
      WatchTransfer.shared.activeSessionId = writer.manifest.sessionId
      WatchTransfer.shared.pauseForRecording()
      wire(writer: writer, motion: motion)
      try await workout.recover(expectedStartMs: writer.manifest.startedAtEpochMs)
      // Counted only now that the workout session is really back; a failed resume leaves the manifest as it was.
      do { try writer.markResumed() } catch { log("manifest_error", "\(error)") }
      unfinished.removeAll { $0 == writer.manifest.sessionId }
      await beginRuntime(writer: writer, motion: motion, coach: true)
      return true
    } catch {
      writer?.flushAll()
      writer = nil
      motion = nil
      WatchTransfer.shared.activeSessionId = nil
      phase = .idle
      return false
    }
  }

  /// A resume was not possible: end the system workout session the relaunch found and keep what was recorded.
  func abandonRecovered() async {
    guard phase == .idle else { return } // never end a live workout or close the folder being written
    await workout.endOrphanedSession()
    keepUnfinished()
  }

  /// A line in `events.csv`.
  func note(_ kind: String, _ detail: String) { log(kind, detail) }

  private func startThermalLog() {
    if let t = thermalObserver { NotificationCenter.default.removeObserver(t) }
    log(ThermalLog.kind, ThermalLog.label(ProcessInfo.processInfo.thermalState))
    thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.log(ThermalLog.kind, ThermalLog.label(ProcessInfo.processInfo.thermalState)) }
    }
  }

  private func stopThermalLog() {
    if let t = thermalObserver { NotificationCenter.default.removeObserver(t) }
    thermalObserver = nil
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
    stopThermalLog()
    UserDefaults.standard.set(hrWatch.missedEntireSession(endingAt: clock), forKey: Self.hrMissedKey)
    hrWatch.stop()
    hrOff = false
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
    WatchTransfer.shared.announceFinished(id)
    WatchTransfer.shared.sendUnsent()
    statusMessage = "Saved \(id)"
    refreshUnfinished()
    phase = .idle
  }

  /// A short-lived notice over the running screen.
  private func flash(_ text: String) {
    toast = text
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      if toast == text { toast = nil }
    }
  }

  /// Called once a second by the coach and every 10 s by the watchdog.
  func checkHeartRate() {
    guard phase == .running else { return }
    let off = hrWatch.isOff(at: clock)
    guard off != hrOff else { return }
    hrOff = off
    if off { workout.onEvent?("hr_off", "no heart-rate sample") }
  }

  /// Shown on the Ready screen: saving workouts was declined, or the last session never produced a sample.
  var heartRateWarning: Bool {
    workout.workoutShareDenied || UserDefaults.standard.bool(forKey: Self.hrMissedKey)
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
    alarmTimer?.invalidate()
    alarmTimer = nil
    alarm = nil
    // A fault that arrived while this one was up is shown now, not lost.
    if let next = alarmGate.dismiss() { showAlarm(next) }
  }

  private func showAlarm(_ message: String) {
    alarm = message
    WKInterfaceDevice.current().play(.failure)
    alarmTimer?.invalidate()
    alarmTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in WKInterfaceDevice.current().play(.failure) }
  }

  private func raiseAlarm(_ message: String) {
    guard phase == .running else { return }
    log("alarm", message) // every raise is logged, whatever the gate then decides
    switch alarmGate.raise(message, at: clock) {
    case .alarm:
      showAlarm(message)
    case .toast:
      // Already acknowledged and still true: a short note in the band and one buzz, never the full-screen alarm again.
      WKInterfaceDevice.current().play(.failure)
      flash(message)
    case .ignore:
      break
    }
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
      Task { @MainActor in
        guard let self else { return }
        self.hrWatch.sample(at: self.clock)
        if self.hrOff { writer.append(.events, Lines.event(epochMs: Clock.epochMs(), kind: "hr_on", detail: "heart-rate sample after off")) }
        self.hrOff = false
        self.heartRate = Int(bpm.rounded())
      }
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
    checkHeartRate()
    guard phase == .running, let motion else { return }
    let total = motion.totalRawSamples
    if !sawFirstSample {
      if total > 0 {
        sawFirstSample = true
        alarmGate.clear("Motion never started")
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
      alarmGate.clear("No motion samples for \(Int(Self.stallSeconds)) s") // flowing again: a later stall alarms afresh
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
