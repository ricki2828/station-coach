import AVFoundation
import CoachKit
import CoachUI
import Foundation
import SwiftUI
import WatchKit

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
  /// Everything that must survive a relaunch (CoachKit); checkpointed to `coach-checkpoint.json`.
  private var state: CoachSessionState?
  private var machine: SessionMachine? {
    get { state?.machine }
    set { if let newValue { state?.machine = newValue } }
  }
  private var scheduler = CueScheduler()
  private let counter = WallBallTally()
  private var ticker: Timer?
  private var midCueDone: Set<Int> {
    get { state?.midCueDone ?? [] }
    set { state?.midCueDone = newValue }
  }
  private var jogInDone: Set<Int> {
    get { state?.jogInDone ?? [] }
    set { state?.jogInDone = newValue }
  }
  private var announcedSets: Set<Int> {
    get { state?.announcedSets ?? [] }
    set { state?.announcedSets = newValue }
  }
  private var repCorrection: Int {
    get { state?.repCorrection ?? 0 }
    set { state?.repCorrection = newValue }
  }
  private var noRepLog: NoRepLog {
    get { state?.noRepLog ?? NoRepLog() }
    set { state?.noRepLog = newValue }
  }
  /// NO REP button and Undo chip timing (CoachKit).
  private var noRepRest = NoRepRest()
  private var noRepShown: Bool { noRepRest.shown }
  private var noRepAnnounced: Bool {
    get { state?.noRepAnnounced ?? false }
    set { state?.noRepAnnounced = newValue }
  }
  private var checkpointer = CoachCheckpointer()
  /// Coached sessions finished on this watch: the first one gets the baseline lines.
  /// Per athlete code (athletes share a watch on gym day). Only a session that ran to the end counts: one ended early
  /// never says the baseline line, so it must not use the first-session status up.
  private var finishedKey: String { "coachedSessionsFinished." + recorder.athlete }
  private var isFirstSession: Bool { UserDefaults.standard.integer(forKey: finishedKey) == 0 }
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
    var fresh = CoachSessionState(plan: plan)
    fresh.machine.start(at: nowMs)
    state = fresh
    checkpointer = CoachCheckpointer()
    scheduler = CueScheduler()
    noRepRest = NoRepRest()
    lastLabel = nil
    let c = counter
    recorder.onMotionMagnitude = { t, mag in c.feed(t, mag) }
    active = true
    beginStep(announce: false)
    // One line at START: the target and what to do with run 1, then run 1's own target.
    if let m = machine, let first = m.current {
      offer(.planAndRun, CoachCopy.sessionStart(plan: plan, isFirst: isFirstSession) + " "
        + CoachCopy.runStart(run: first, after: nil, deltaSeconds: 0, transitionSeconds: plan.transitionSeconds))
    }
    checkpoint()
    startTicker()
    refresh()
  }

  private func startTicker() {
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  /// Picks a session up after the app was killed mid-session: the workout reattached, the files appended to, and the
  /// coach state restored from `coach-checkpoint.json`. False when nothing could be resumed; the caller then closes the
  /// folder, which writes `coach.json` from the checkpoint so the splits still reach History.
  func resume() async -> Bool {
    guard !active, recorder.phase == .idle, let root = try? SessionFiles.defaultRoot(),
          let found = CoachCheckpoint.latestResumable(in: root, nowMs: nowMs) else { return false }
    guard await recorder.resume(folder: found.folder) else { return false }
    state = found.checkpoint.state
    checkpointer = CoachCheckpointer(startingSeq: found.checkpoint.seq + 1)
    scheduler = CueScheduler()
    noRepRest = NoRepRest()
    lastLabel = nil
    finish = nil
    let c = counter
    recorder.onMotionMagnitude = { t, mag in c.feed(t, mag) }
    active = true
    if let step = machine?.current {
      recorder.note("recovered_resume", "step=\(step.index) splits=\(machine?.splits.count ?? 0) seq=\(found.checkpoint.seq)\(found.usedBackup ? " backup" : "")")
    }
    beginStep(announce: false)
    checkpoint()
    startTicker()
    refresh()
    return true
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
      checkpoint()
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
      checkpoint()
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
    checkpoint()
    refresh()
  }

  /// A rep that did not count: back onto reps left. Only offered in the rest between sets.
  func noRep() {
    guard active, noRepShown, let step = machine?.current, step.activity == .wallBalls else { return }
    let set = WallBallProgress.setIndex(repsDone: repsDone(step), sets: step.sets)
    noRepLog.add(NoRepEvent(tMs: nowMs, setIndex: set, stepIndex: step.index))
    noRepRest.noted(nowMs: nowMs)
    WKInterfaceDevice.current().play(.click)
    if !noRepAnnounced {
      noRepAnnounced = true
      offer(.noRep, CoachCopy.noRepNoted)
    }
    checkpoint()
    refresh()
  }

  /// Takes back the last NO REP of this step: reps left goes back down.
  func undoNoRep() {
    guard active, let step = machine?.current, noRepLog.undoLast(inStep: step.index) != nil else { return }
    noRepRest.clearUndo()
    WKInterfaceDevice.current().play(.retry)
    checkpoint()
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
    state?.bank(step: step, repTimesMs: WallBallTally.milliseconds(counter.snapshot().times))
    noRepRest.hide()
    scheduler.drop(.noRep)
    counter.pause()
  }

  private func beginStep(announce: Bool = true) {
    guard let m = machine, let step = m.current else { return }
    scheduler.drop(.jogIn) // still waiting out the cue gap when the athlete moved on: no use now
    applyLabel()
    if step.activity == .wallBalls {
      let fresh = state?.enterWallBalls(step) ?? true
      let earlier = (state?.repsByStep[step.index] ?? []).map { Double($0) / 1000 }
      counter.begin(step: step.index, fresh: fresh, earlier: earlier)
      noRepRest.reset(count: counter.snapshot().count, nowMs: nowMs)
      // Sets already passed (an undo back into the step, or a resume) are not announced again.
      state?.resetAnnouncedSets(for: step, repsDone: repsDone(step))
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
        checkpoint()
      }
      if step.isRun, !jogInDone.contains(step.index),
         CoachCopy.jogInDue(run: step, next: m.next, elapsedSeconds: elapsed, transitionSeconds: m.plan.transitionSeconds) {
        jogInDone.insert(step.index)
        offer(.jogIn, CoachCopy.jogIn)
        checkpoint()
      }
      if step.activity == .wallBalls {
        announceSets(step)
        if checkpointer.repCountChanged(counter.snapshot().count) { checkpoint() } // a rep was counted: at most one write per rep
      }
      refresh()
    }
    pump()
  }

  private func repsDone(_ step: PlanStep) -> Int {
    state?.repsDone(step, counted: counter.snapshot().count) ?? 0
  }

  /// Writes `coach-checkpoint.json` (atomic). Called on every change that matters, never on the 1 s tick itself.
  private func checkpoint() {
    guard active, let s = state, let folder = recorder.sessionFolder else { return }
    let snap = counter.snapshot()
    if let failure = checkpointer.save(s, liveRepTimesMs: WallBallTally.milliseconds(snap.times), liveCount: snap.count, folder: folder, nowMs: nowMs) {
      recorder.note("checkpoint_error", failure)
    }
  }

  /// Said only while the count is trustworthy: a "Set done" spoken at a wrong count is worse than silence.
  private func announceSets(_ step: PlanStep) {
    let trusted = counter.snapshot().confidence == .high
    for done in state?.newlyDoneSets(step, repsDone: repsDone(step)) ?? [] where trusted {
      offer(.wallBallSet, CoachCopy.wallBallSetDone(nextSet: done.next))
    }
  }

  private func offer(_ kind: CoachCueKind, _ text: String) {
    // The buzz is chosen now, from the same delta as the words, so a cue that waits in the queue still matches itself.
    let haptic = CueHaptic.for(kind, deltaSeconds: machine?.deltaSeconds(at: nowMs) ?? 0)
    scheduler.offer(CoachCue(kind: kind, text: text, createdAt: clock, haptic: haptic))
    pump()
  }

  private func pump() {
    guard recorder.phase == .running, let cue = scheduler.next(at: clock, speaking: recorder.cues.isSpeaking) else { return }
    recorder.cues.speak(cue.text, haptic: cue.haptic ?? CueHaptic.for(cue.kind, deltaSeconds: 0))
  }

  // MARK: Screen

  private func refresh() {
    guard active, let m = machine, let step = m.current else { screen = nil; return }
    let now = nowMs
    let delta = m.deltaSeconds(at: now)
    let elapsed = m.stepElapsedSeconds(at: now)
    let next = m.next.map { "Next: \($0.name)" } ?? "Next: Finish"
    let ladder = LadderTick.ladder(for: m.plan, currentIndex: step.index)
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
      var model = StepScreenModel(
        kind: .reps, activity: .wallBalls, title: step.name, dominant: "\(left)",
        dominantLabel: "Reps left, \(left)", secondary: left == 0 ? "Done" : "Set \(setNo) \u{00B7} \(setSize)",
        secondaryLabel: left == 0 ? "All reps done" : "Set \(setNo) of \(step.sets.count), \(setSize) reps",
        next: next, isLast: m.next == nil, deltaSeconds: delta, hrBpm: common.hr, hrOff: recorder.hrOff, toast: common.toast,
        alarm: common.alarm, approximate: approx, noRepVisible: noRepShown, noRepCount: noRepLog.count(inStep: step.index),
        noRepUndo: noRepRest.undoVisible(nowMs: now, taps: noRepLog.count(inStep: step.index)))
      model.ladder = ladder
      screen = model
      return
    }
    let transition = m.label(at: now) == .transition
    var model = StepScreenModel(
      kind: step.isRun ? .run : .time, activity: step.activity, title: step.name, badge: transition ? "Transition" : nil,
      dominant: Fmt.clock(elapsed), dominantLabel: "\(step.isRun ? "Run" : "Station") time, \(Fmt.spoken(elapsed))",
      secondary: target, secondaryLabel: targetLabel, next: next, isLast: m.next == nil, deltaSeconds: delta,
      hrBpm: common.hr, hrOff: recorder.hrOff, toast: common.toast, alarm: common.alarm)
    model.ladder = ladder
    screen = model
  }

  private func updateNoRepRest(_ step: PlanStep, count: Int, done: Int) {
    let was = noRepRest.shown
    noRepRest.update(nowMs: nowMs, count: count, done: done, sets: step.sets)
    if was, !noRepRest.shown { scheduler.drop(.noRep) } // throwing resumed: too late to say it
  }

  // MARK: Finish

  /// Seconds after a normal finish during which UNDO reopens the last step. The recorder keeps running.
  static let undoWindowSeconds = 10

  private func finishSession(early: Bool) {
    guard let m = machine, let result = state?.makeResult(early: early, endedAtEpochMs: nowMs) else { return }
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
      + " " + CoachCopy.finishPersonality(totalSeconds: total, plannedSeconds: planned, isFirst: isFirstSession, early: early, saved: saved)
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
    if finish?.early == false { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: finishedKey) + 1, forKey: finishedKey) }
    // Clean finish: coach.json is the record. The checkpoint must not travel to the phone in the file list.
    if let folder = recorder.sessionFolder { CoachCheckpoint.remove(from: folder) }
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
    checkpoint()
    refresh()
  }
}
