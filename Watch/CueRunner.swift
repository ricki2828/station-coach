import AVFoundation
import CoachKit
import Foundation
import WatchKit

/// Every N seconds: a haptic, plus a spoken phrase when headphones are the audio route. Each cue is
/// logged with the route outputs at that moment and whether the synthesizer reported finish.
/// Adapted from run-solo's CuePlayer (AudioToolbox vibration replaced by `WKInterfaceDevice` haptics).
final class CueRunner: NSObject, AVSpeechSynthesizerDelegate {
  static let finishTimeout: TimeInterval = 15

  var onCue: ((CueEvent) -> Void)?
  var onNote: ((String, String) -> Void)?
  var onIssued: ((String) -> Void)?

  private let synth = AVSpeechSynthesizer()
  private var timer: Timer?
  private var nextId = 0
  private var phraseIndex = 0
  private var lastCueId: Int?
  private var utteranceIds: [ObjectIdentifier: Int] = [:]
  private var inFlight: [Int: (phrase: String, outputs: [String])] = [:]
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

  func start(interval: TimeInterval) {
    stop()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.fire() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    synth.stopSpeaking(at: .immediate)
    release()
  }

  /// "Didn't hear it": flags the most recent cue.
  func markLastMissed() {
    guard let id = lastCueId else { return }
    let route = Self.route()
    emit(id, .missed, mode: .speech, headphones: route.headphones, outputs: route.outputs, phrase: "", detail: "user flagged")
  }

  func fire() {
    nextId += 1
    let id = nextId
    lastCueId = id
    let phrase = CuePhrases.phrase(at: phraseIndex)
    phraseIndex += 1
    WKInterfaceDevice.current().play(.notification)

    // The route only shows Bluetooth once the session is active, so activate first and then look.
    var activationError: String?
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
      try session.setActive(true)
    } catch {
      activationError = "\(error)"
    }
    let route = Self.route()
    guard route.headphones, activationError == nil else {
      emit(id, .issued, mode: .hapticOnly, headphones: route.headphones, outputs: route.outputs, phrase: phrase,
           detail: activationError.map { "audio session failed: \($0)" } ?? "no headphones; haptic only")
      release()
      onIssued?(phrase + " (haptic only)")
      return
    }
    emit(id, .issued, mode: .speech, headphones: true, outputs: route.outputs, phrase: phrase, detail: "")
    onIssued?(phrase)
    let utterance = AVSpeechUtterance(string: phrase)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utteranceIds[ObjectIdentifier(utterance)] = id
    inFlight[id] = (phrase, route.outputs)
    synth.speak(utterance)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
      guard let self, let ctx = self.inFlight.removeValue(forKey: id) else { return }
      self.emit(id, .timeout, mode: .speech, headphones: true, outputs: ctx.outputs, phrase: ctx.phrase, detail: "no finish in \(Int(Self.finishTimeout))s")
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
      self.emit(id, kind, mode: .speech, headphones: true, outputs: ctx.outputs, phrase: ctx.phrase, detail: "")
      if self.inFlight.isEmpty { self.release() }
    }
  }

  // MARK: Helpers

  private func emit(_ id: Int, _ kind: CueEvent.Kind, mode: CueEvent.Mode, headphones: Bool, outputs: [String], phrase: String, detail: String) {
    onCue?(CueEvent(epochMs: Clock.epochMs(), cueId: id, kind: kind, mode: mode, headphones: headphones, outputs: outputs, phrase: phrase, detail: detail))
  }

  private func release() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  static func route() -> (outputs: [String], headphones: Bool) {
    let outs = AVAudioSession.sharedInstance().currentRoute.outputs
    let names = outs.map { "\($0.portType.rawValue)/\($0.portName)" }
    return (names, RouteClassifier.isHeadphones(portTypes: outs.map { $0.portType.rawValue }))
  }
}
