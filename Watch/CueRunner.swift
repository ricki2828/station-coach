import AVFoundation
import CoachKit
import Foundation
import WatchKit

/// Every N seconds: a haptic plus a spoken phrase, always attempted. Each cue is logged with the
/// audio mode, the route outputs at that moment and whether the synthesizer reported finish.
/// Adapted from run-solo's CuePlayer (AudioToolbox vibration replaced by `WKInterfaceDevice` haptics).
final class CueRunner: NSObject, AVSpeechSynthesizerDelegate {
  static let finishTimeout: TimeInterval = 15
  /// A "didn't hear" tap applies to the latest cue only if it was issued this recently.
  static let missedWindow: TimeInterval = 30

  var audioMode: AudioMode = .shortForm

  var onCue: ((CueEvent) -> Void)?
  var onNote: ((String, String) -> Void)?
  var onIssued: ((String) -> Void)?

  private let synth = AVSpeechSynthesizer()
  private var timer: Timer?
  private var nextId = 0
  private var phraseIndex = 0
  private var lastCueId: Int?
  private var lastCueAt = Date.distantPast
  private var longFormError: String?
  private var utteranceIds: [ObjectIdentifier: Int] = [:]
  private var inFlight: [Int: (phrase: String, outputs: [String], headphones: Bool)] = [:]
  private var observers: [NSObjectProtocol] = []

  override init() {
    super.init()
    synth.delegate = self
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
      let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
      self?.onNote?("route_change", "reason=\(reason) outputs=\(Self.route().outputs.joined(separator: ";"))")
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
      let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
      self?.onNote?("audio_interruption", "type=\(type)")
    })
  }

  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

  /// Call once at session start (before `start`). Mode B activates the long-form session here and keeps
  /// it active until `stop()`; mode A does nothing now and activates before each cue.
  func prepare() async {
    guard audioMode == .longForm else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
      _ = try await session.activate(options: [])
      longFormError = nil
      onNote?("audio_mode", "B long-form activated outputs=\(Self.route().outputs.joined(separator: ";"))")
    } catch {
      longFormError = "\(error)"
      onNote?("audio_mode", "B long-form activation failed: \(error)")
    }
  }

  func start(interval: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.fire() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    synth.stopSpeaking(at: .immediate)
    release(force: true)
  }

  /// "Didn't hear it": flags the most recent cue, if it was issued within `missedWindow` seconds.
  /// Returns false when there is nothing recent to flag.
  @discardableResult
  func markLastMissed() -> Bool {
    guard let id = lastCueId, Date().timeIntervalSince(lastCueAt) <= Self.missedWindow else { return false }
    let route = Self.route()
    emit(id, .missed, mode: .speech, headphones: route.headphones, outputs: route.outputs, phrase: "", detail: "user flagged")
    return true
  }

  func fire() {
    nextId += 1
    let id = nextId
    lastCueId = id
    lastCueAt = Date()
    let phrase = CuePhrases.phrase(at: phraseIndex)
    phraseIndex += 1
    WKInterfaceDevice.current().play(.notification)

    // Speech is always attempted. The route is read after activation and only logged, never used to skip.
    var problem: String?
    switch audioMode {
    case .shortForm:
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try session.setActive(true)
      } catch {
        problem = "audio session failed: \(error)"
      }
    case .longForm:
      if let e = longFormError { problem = "long-form activation failed at start: \(e)" }
    }
    let route = Self.route()
    emit(id, .issued, mode: .speech, headphones: route.headphones, outputs: route.outputs, phrase: phrase, detail: problem ?? "")
    onIssued?(phrase)
    let utterance = AVSpeechUtterance(string: phrase)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utteranceIds[ObjectIdentifier(utterance)] = id
    inFlight[id] = (phrase, route.outputs, route.headphones)
    synth.speak(utterance)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
      guard let self, let ctx = self.inFlight.removeValue(forKey: id) else { return }
      self.utteranceIds = self.utteranceIds.filter { $0.value != id }
      self.emit(id, .timeout, mode: .speech, headphones: ctx.headphones, outputs: ctx.outputs, phrase: ctx.phrase, detail: "no finish in \(Int(Self.finishTimeout))s")
    }
  }

  // MARK: AVSpeechSynthesizerDelegate

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    complete(utterance, .finished)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    complete(utterance, .cancelled)
  }

  private func complete(_ utterance: AVSpeechUtterance, _ kind: CueEvent.Kind) {
    DispatchQueue.main.async {
      guard let id = self.utteranceIds.removeValue(forKey: ObjectIdentifier(utterance)),
            let ctx = self.inFlight.removeValue(forKey: id) else { return }
      self.emit(id, kind, mode: .speech, headphones: ctx.headphones, outputs: ctx.outputs, phrase: ctx.phrase, detail: "")
      if self.inFlight.isEmpty { self.release(force: false) }
    }
  }

  // MARK: Helpers

  private func emit(_ id: Int, _ kind: CueEvent.Kind, mode: CueEvent.Mode, headphones: Bool, outputs: [String], phrase: String, detail: String) {
    onCue?(CueEvent(epochMs: Clock.epochMs(), cueId: id, kind: kind, mode: mode, headphones: headphones, outputs: outputs, phrase: phrase, detail: detail, audioMode: audioMode.rawValue))
  }

  /// Mode A deactivates after each cue; mode B stays active until `stop()` (`force`).
  private func release(force: Bool) {
    guard force || audioMode == .shortForm else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  static func route() -> (outputs: [String], headphones: Bool) {
    let outs = AVAudioSession.sharedInstance().currentRoute.outputs
    let names = outs.map { "\($0.portType.rawValue)/\($0.portName)" }
    return (names, RouteClassifier.isHeadphones(portTypes: outs.map { $0.portType.rawValue }))
  }
}
