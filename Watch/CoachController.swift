import AVFoundation
import CoachKit
import CoachUI
import Foundation
import SwiftUI
import WatchKit

/// Wall-ball rep counter shared with the motion thread.
final class LockedCounter {
  private let lock = NSLock()
  private var counter = WallBallCounter()
  private var enabled = false

  /// Start counting; `fresh` starts from zero, otherwise the earlier count carries on (undo back into a step).
  func begin(fresh: Bool) {
    lock.lock(); defer { lock.unlock() }
    if fresh { counter = WallBallCounter() }
    enabled = true
  }

  func pause() {
    lock.lock(); defer { lock.unlock() }
    enabled = false
  }

  func feed(_ t: Double, _ magnitude: Double) {
    lock.lock(); defer { lock.unlock() }
    guard enabled else { return }
    counter.add(t: t, magnitude: magnitude)
  }

  func snapshot() -> (count: Int, confidence: WallBallCounter.Confidence, times: [Double]) {
    lock.lock(); defer { lock.unlock() }
    return (counter.count, counter.confidence, counter.repTimes)
  }
}

/// Runs a coached session on top of the M1 recorder: the plan drives the screens and the cues, and each
/// phase change writes the M1 label, so the recorder's files and pass marks work as before.
@MainActor
final class CoachController: ObservableObject {
  @Published private(set) var screen: StepScreenModel?
  @Published private(set) var finish: FinishScreenModel?
  @Published private(set) var active = false
  @Published var showMenu = false
  /// From the audio route after the session was activated in the chosen mode. Nil until known.
  @Published private(set) var headphones: Bool?

  private let recorder: RecorderController
  private let transfer = WatchTransfer.shared
  private var machine: SessionMachine?
  private var scheduler = CueScheduler()
  private let counter = LockedCounter()
  private var ticker: Timer?
  private var midCueDone = Set<Int>()
  private var jogInDone = Set<Int>()
  private var announcedSets = Set<Int>()
  private var repCorrection = 0
  private var repsByStep: [Int: [Int64]] = [:]
  private var correctionByStep: [Int: Int] = [:]
  private var noReps: [NoRepEvent] = []
  /// No-reps tapped in the current wall-ball step; they come off the valid count.
  private var noRepsInStep = 0
  private var noRepsByStep: [Int: Int] = [:]
  /// The NO REP button is up from the rest (set done, or reps paused 4 s) until the next rep is counted.
  private var noRepShown = false
  private var lastSeenCount = 0
  private var lastRepChangeMs: Int64 = 0
  private var noRepAnnounced = false
  private var enteredWallBalls = Set<Int>()
  private var lastLabel: Activity?
  private var finishTask: Task<Void, Never>?
  private var finishCueText = ""

  init(recorder: RecorderController) {
    self.recorder = recorder
    recorder.cues.onRouteStatus = { [weak self] present in Task { @MainActor in self?.headphones = present } }
  }

  /// Re-reads the route for the Ready chip (a brief activation; later changes arrive as route-change events).
  func refreshAudioRoute() { recorder.cues.probeRoute() }

  private var nowMs: Int64 { Clock.epochMs() }
  private var clock: TimeInterval { Date().timeIntervalSinceReferenceDate }

  // MARK: Ready

  var readyModel: ReadyScreenModel {
    guard let plan = transfer.plan else { return transfer.planChecked ? .noPlan : .loading }
    var chips: [String] = []
    if headphones == false { chips.append("No headphones: cues by vibration") }
    if recorder.heartRateWarning { chips.append("Heart rate off. The coach still works.") }
    if let m = recorder.statusMessage, recorder.phase == .idle, !m.hasPrefix("Saved") { chips.append(m) }
    let device = WKInterfaceDevice.current()
    device.isBatteryMonitoringEnabled = true
    let level = Double(device.batteryLevel)
    var battery: String?
    if plan.type == .fullSim, level >= 0, level < 0.6 {
      battery = "Battery \(Int((level * 100).rounded()))%. A full sim needs about 60%."
    }
    return .ready(ReadyInfo(
      sessionName: plan.title, targetText: Fmt.clock(plan.plannedSeconds),
      chips: chips, batteryLine: battery))
  }

  // MARK: Session

  func start() async {
    guard let plan = transfer.plan, recorder.phase == .idle, !active else { return }
    finish = nil
    await recorder.start(coach: true, transitionSeconds: plan.transitionSeconds)
    guard recorder.phase == .running else { return }
    var m = SessionMachine(plan: plan)
    m.start(at: nowMs)
    machine = m
    scheduler = CueScheduler()
    midCueDone = []
    jogInDone = []
    announcedSets = []
    repCorrection = 0
    repsByStep = [:]
    correctionByStep = [:]
    noReps = []
    noRepsInStep = 0
    noRepsByStep = [:]
    noRepShown = false
    noRepAnnounced = false
    enteredWallBalls = []
    lastLabel = nil
    let c = counter
    recorder.onMotionMagnitude = { t, mag in c.feed(t, mag) }
    active = true
    beginStep()
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    refresh()
  }

  func advance() {
    guard var m = machine, active else { return }
    let before = m.current
    let result = m.advance(at: nowMs)
    machine = m
    switch result {
    case .started:
      leaveStep(before)
      WKInterfaceDevice.current().play(.click)
      beginStep()
    case .finished:
      leaveStep(before)
      WKInterfaceDevice.current().play(.click)
      finishSession(early: false)
    case .ignored, .notRunning:
      break // a double fire inside 3 s changes nothing
    }
    refresh()
  }

  func undo() {
    guard var m = machine, active else { return }
    if m.undo(at: nowMs) {
      machine = m
      WKInterfaceDevice.current().play(.retry)
      beginStep(announce: false)
    }
    showMenu = false
    refresh()
  }

  func endEarly() {
    guard var m = machine, active else { return }
    leaveStep(m.current)
    m.end(at: nowMs)
    machine = m
    showMenu = false
    finishSession(early: true)
  }

  func adjustReps(_ delta: Int) {
    guard active else { return }
    repCorrection += delta
    WKInterfaceDevice.current().play(.click)
    refresh()
  }

  /// A rep that did not count: back onto reps left. Only offered in the rest between sets.
  func noRep() {
    guard active, noRepShown, let step = machine?.current, step.activity == .wallBalls else { return }
    let set = WallBallProgress.setIndex(repsDone: repsDone(step), sets: step.sets)
    noReps.append(NoRepEvent(tMs: nowMs, setIndex: set))
    noRepsInStep += 1
    WKInterfaceDevice.current().play(.click)
    if !noRepAnnounced {
      noRepAnnounced = true
      offer(.wallBallSet, CoachCopy.noRepNoted)
    }
    refresh()
  }

  func dismissFinish() {
    // Only once the files are closed; before that the finish screen has no DONE.
    guard finish?.saving != true, finish?.undoSecondsLeft == nil else { return }
    finish = nil
    ticker?.invalidate()
    ticker = nil
  }

  // MARK: Step changes

  /// Banks the wall-ball reps of the step just left and stops counting.
  private func leaveStep(_ step: PlanStep?) {
    guard let step, step.activity == .wallBalls else { return }
    let snap = counter.snapshot()
    repsByStep[step.index] = snap.times.map { Int64(($0 * 1000).rounded()) }
    correctionByStep[step.index] = repCorrection
    noRepsByStep[step.index] = noRepsInStep
    noRepShown = false
    counter.pause()
  }

  private func beginStep(announce: Bool = true) {
    guard let m = machine, let step = m.current else { return }
    scheduler.drop(.jogIn) // still waiting out the cue gap when the athlete moved on: no use now
    applyLabel()
    if step.activity == .wallBalls {
      let fresh = !enteredWallBalls.contains(step.index)
      enteredWallBalls.insert(step.index)
      counter.begin(fresh: fresh)
      repCorrection = fresh ? 0 : (correctionByStep[step.index] ?? 0)
      noRepsInStep = fresh ? 0 : (noRepsByStep[step.index] ?? 0)
      noRepShown = false
      lastSeenCount = counter.snapshot().count
      lastRepChangeMs = nowMs
      // Sets already passed (an undo back into the step) are not announced again.
      announcedSets = []
      var cumulative = 0
      for (k, size) in step.sets.enumerated() {
        cumulative += size
        if repsDone(step) >= cumulative { announcedSets.insert(k) }
      }
    } else {
      counter.pause()
    }
    guard announce else { return }
    if step.isRun {
      let before = step.index > 0 ? m.plan.steps[step.index - 1] : nil
      offer(.planAndRun, CoachCopy.runStart(run: step, after: before, deltaSeconds: m.deltaSeconds(at: nowMs), transitionSeconds: m.plan.transitionSeconds))
    } else {
      offer(.stationIntro, CoachCopy.stationIntro(step))
    }
  }

  private func applyLabel() {
    guard let m = machine, let label = m.label(at: nowMs), label != lastLabel else { return }
    lastLabel = label
    recorder.tap(label, haptic: false)
  }

  // MARK: Tick

  private func tick() {
    recorder.checkHeartRate()
    if active, let m = machine, let step = m.current {
      applyLabel()
      let elapsed = m.stepElapsedSeconds(at: nowMs)
      if !step.isRun, step.activity != .wallBalls, !midCueDone.contains(step.index), elapsed * 2 >= step.targetSeconds,
         let text = CoachCopy.midStation(step) {
        midCueDone.insert(step.index)
        offer(.midStation, text)
      }
      if step.isRun, !jogInDone.contains(step.index),
         CoachCopy.jogInDue(run: step, next: m.next, elapsedSeconds: elapsed, transitionSeconds: m.plan.transitionSeconds) {
        jogInDone.insert(step.index)
        offer(.jogIn, CoachCopy.jogIn)
      }
      if step.activity == .wallBalls { announceSets(step) }
      refresh()
    }
    pump()
  }

  private func repsDone(_ step: PlanStep) -> Int {
    let total = step.reps ?? 100
    return min(total, max(0, counter.snapshot().count + repCorrection - noRepsInStep))
  }

  /// Said only while the count is trustworthy: a "Set done" spoken at a wrong count is worse than silence.
  private func announceSets(_ step: PlanStep) {
    let done = repsDone(step)
    let trusted = counter.snapshot().confidence == .high
    var cumulative = 0
    for (k, size) in step.sets.enumerated() {
      cumulative += size
      if done >= cumulative, !announcedSets.contains(k) {
        announcedSets.insert(k)
        let next = k + 1 < step.sets.count ? step.sets[k + 1] : nil
        if trusted { offer(.wallBallSet, CoachCopy.wallBallSetDone(nextSet: next)) }
      }
    }
  }

  private func offer(_ kind: CoachCueKind, _ text: String) {
    scheduler.offer(CoachCue(kind: kind, text: text, createdAt: clock))
    pump()
  }

  private func pump() {
    guard recorder.phase == .running, let cue = scheduler.next(at: clock, speaking: recorder.cues.isSpeaking) else { return }
    recorder.cues.speak(cue.text)
  }

  // MARK: Screen

  private func refresh() {
    guard active, let m = machine, let step = m.current else { screen = nil; return }
    let now = nowMs
    let delta = m.deltaSeconds(at: now)
    let elapsed = m.stepElapsedSeconds(at: now)
    let next = m.next.map { "Next: \($0.name)" } ?? "Next: Finish"
    let common = (hr: recorder.hrOff ? nil : recorder.heartRate, toast: recorder.toast, alarm: recorder.alarm)
    let target = "/ \(Fmt.clock(step.targetSeconds))"
    let targetLabel = "Target \(Fmt.spoken(step.targetSeconds))"
    if step.activity == .wallBalls {
      let total = step.reps ?? 100
      let done = repsDone(step)
      let left = total - done
      let snap = counter.snapshot()
      updateNoRepRest(step, count: snap.count, done: done)
      var cumulative = 0
      var setNo = step.sets.count, setSize = step.sets.last ?? 0
      for (k, size) in step.sets.enumerated() {
        cumulative += size
        if done < cumulative { setNo = k + 1; setSize = size; break }
      }
      let approx = snap.count >= 3 && snap.confidence == .low
      screen = StepScreenModel(
        kind: .reps, activity: .wallBalls, title: step.name, dominant: "\(left)",
        dominantLabel: "Reps left, \(left)", secondary: left == 0 ? "Done" : "Set \(setNo) \u{00B7} \(setSize)",
        secondaryLabel: left == 0 ? "All reps done" : "Set \(setNo) of \(step.sets.count), \(setSize) reps",
        next: next, isLast: m.next == nil, deltaSeconds: delta, hrBpm: common.hr, hrOff: recorder.hrOff, toast: common.toast,
        alarm: common.alarm, approximate: approx, noRepVisible: noRepShown, noRepCount: noRepsInStep)
      return
    }
    let transition = m.label(at: now) == .transition
    screen = StepScreenModel(
      kind: step.isRun ? .run : .time, activity: step.activity, title: step.name, badge: transition ? "Transition" : nil,
      dominant: Fmt.clock(elapsed), dominantLabel: "\(step.isRun ? "Run" : "Station") time, \(Fmt.spoken(elapsed))",
      secondary: target, secondaryLabel: targetLabel, next: next, isLast: m.next == nil, deltaSeconds: delta,
      hrBpm: common.hr, hrOff: recorder.hrOff, toast: common.toast, alarm: common.alarm)
  }

  /// Raises the NO REP button when a set has just been completed or the reps have paused for 4 s; a new rep drops it.
  private func updateNoRepRest(_ step: PlanStep, count: Int, done: Int) {
    if count != lastSeenCount {
      lastSeenCount = count
      lastRepChangeMs = nowMs
      noRepShown = false
      return
    }
    guard !noRepShown, count > 0 else { return }
    let paused = nowMs - lastRepChangeMs >= Self.noRepPauseMs
    var cumulative = 0
    let setEnd = step.sets.contains { cumulative += $0; return done == cumulative }
    if paused || setEnd { noRepShown = true }
  }

  static let noRepPauseMs: Int64 = 4000

  // MARK: Finish

  /// Seconds after a normal finish during which UNDO reopens the last step. The recorder keeps running.
  static let undoWindowSeconds = 10

  private func finishSession(early: Bool) {
    guard let m = machine, let started = m.startMs else { return }
    let ended = m.endMs ?? nowMs
    let allReps = repsByStep.values.flatMap { $0 }.sorted()
    let result = CoachResult(plan: m.plan, splits: m.splits, early: early, repTimesMs: allReps, repCorrection: correctionByStep.values.reduce(0, +),
                             startedAtEpochMs: started, endedAtEpochMs: ended, noReps: noReps)
    let saved = writeResult(result)

    let best = result.bestWorstStations
    let total = result.totalSeconds
    let planned = result.plan.plannedSeconds
    let d = total - planned
    let endName = m.splits.last.map { m.plan.steps[$0.stepIndex].name } ?? ""
    let line = early
      ? "Ended at \(endName). \(result.completedStationCount) of \(m.plan.stationCount) stations."
      : (d == 0 ? "On target" : "\(Fmt.gap(d)) \(d < 0 ? "under" : "over") target")
    let missing = m.plan.stationCount - result.completedStationCount
    // The cooldown is not the last station: label it rest until the files close (undo re-labels the step).
    recorder.tap(.rest, haptic: false)
    lastLabel = .rest
    finishCueText = CoachCopy.finish(totalSeconds: total, plannedSeconds: planned, best: best.best, worst: best.worst, early: early)
    finish = FinishScreenModel(
      mode: saved ? .saved : .saveFailed(missing: max(missing, 1)), totalText: Fmt.clock(total), line: line, early: early,
      best: best.best.map { "\($0.0) \(Fmt.delta($0.1))" }, worst: best.worst.map { "\($0.0) \(Fmt.delta($0.1))" },
      saving: false, undoSecondsLeft: early ? nil : Self.undoWindowSeconds,
      totalSeconds: total, stations: FinishScreenModel.stations(from: result))
    active = false
    screen = nil
    celebrate()
    finishTask?.cancel()
    finishTask = Task { @MainActor in
      if !early {
        for left in stride(from: Self.undoWindowSeconds, to: 0, by: -1) {
          finish?.undoSecondsLeft = left
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          if Task.isCancelled { return }
        }
      }
      await completeFinish()
    }
  }

  /// A short success pattern: the one loud moment of the session.
  private func celebrate() {
    let device = WKInterfaceDevice.current()
    device.play(.success)
    Task { @MainActor in
      for (delay, kind) in [(350, WKHapticType.click), (250, .click), (350, .notification)] as [(Int, WKHapticType)] {
        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        device.play(kind)
      }
    }
  }

  private func writeResult(_ result: CoachResult) -> Bool {
    guard let folder = recorder.sessionFolder else { return false }
    do {
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      try enc.encode(result).write(to: folder.appendingPathComponent(CoachResult.fileName), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// The undo window has closed: close the workout and the files.
  private func completeFinish() async {
    finish?.undoSecondsLeft = nil
    finish?.saving = true
    // The finish line is a cue like any other: let it be spoken, and its `finished` event logged, before the
    // writer closes. Anything else still waiting is dropped. Capped at the cue timeout.
    scheduler = CueScheduler()
    offer(.finish, finishCueText)
    var waited = 0.0
    while (scheduler.hasPending || recorder.cues.isSpeaking) && waited < CueRunner.finishTimeout {
      pump()
      try? await Task.sleep(nanoseconds: 250_000_000)
      waited += 0.25
    }
    try? await Task.sleep(nanoseconds: 300_000_000) // the delegate's finished event arrives on the main queue
    recorder.onMotionMagnitude = nil
    await recorder.stop()
    finish?.saving = false
  }

  /// Reopens the last step after an accidental FINISH, while the undo window is open.
  func undoFinish() {
    guard finish?.undoSecondsLeft != nil, var m = machine, m.undo(at: nowMs) else { return }
    finishTask?.cancel()
    finishTask = nil
    machine = m
    if let folder = recorder.sessionFolder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(CoachResult.fileName)) }
    finish = nil
    active = true
    WKInterfaceDevice.current().play(.retry)
    beginStep(announce: false)
    refresh()
  }
}
