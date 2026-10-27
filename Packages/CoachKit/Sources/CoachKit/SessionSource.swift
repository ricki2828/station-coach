import Foundation
#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity
#endif

/// Where sessions come from and where plans go. Today that is only an Apple Watch over WatchConnectivity; the
/// protocol is the seam for another source (a Garmin import, a file drop) without the phone assuming WatchConnectivity.
/// The session files themselves are the contract: docs/FORMAT.md and docs/schema/*.schema.json.
public enum SessionSourceKind: String, Sendable {
  case watchConnectivity
}

/// What happened to a plan handed to a source. The phone maps this to its own send state.
public enum PlanDelivery: Equatable, Sendable {
  case sent
  /// The device cannot do this at all (no WatchConnectivity).
  case unsupported
  /// The channel was not activated yet; the caller should activate it and may retry.
  case notActivated
  /// Paired device without the app installed.
  case appMissing
  /// The channel refused or the plan could not be encoded.
  case failed

  /// The order WatchConnectivity is checked in. Pure, so it is testable off-device.
  public static func decide(supported: Bool, activated: Bool, paired: Bool, appInstalled: Bool) -> PlanDelivery? {
    guard supported else { return .unsupported }
    guard activated else { return .notActivated }
    guard paired, appInstalled else { return .appMissing }
    return nil // clear to send
  }
}

public protocol SessionSource: AnyObject {
  var kind: SessionSourceKind { get }
  /// Whether a device is paired with the app installed and the channel is up.
  var isReady: Bool { get }
  /// Hands the plan to the device. Latest wins; delivery to a sleeping device is the source's business.
  func deliver(plan: SessionPlan) -> PlanDelivery
}

public enum SessionSourceCodec {
  /// The application-context payload for a plan: `["plan": <JSON text>]`, exactly what the phone sent before this seam.
  public static func planContext(_ plan: SessionPlan) throws -> [String: Any] {
    let data = try JSONEncoder().encode(plan)
    return ["plan": String(decoding: data, as: UTF8.self)]
  }
}

#if canImport(WatchConnectivity) && os(iOS)
/// The phone's WatchConnectivity plan channel. It holds the send logic that used to sit in `PhoneTransfer.sendPlan`
/// unchanged; receiving files stays in the `WCSessionDelegate` that owns the session.
public final class WatchConnectivitySource: SessionSource {
  public let kind = SessionSourceKind.watchConnectivity
  private let onNeedsActivation: () -> Void

  /// `onNeedsActivation` is called when a send finds the session not activated (the owner activates it).
  public init(onNeedsActivation: @escaping () -> Void) {
    self.onNeedsActivation = onNeedsActivation
  }

  public var isReady: Bool {
    guard WCSession.isSupported() else { return false }
    let s = WCSession.default
    return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
  }

  public func deliver(plan: SessionPlan) -> PlanDelivery {
    let supported = WCSession.isSupported()
    let s = WCSession.default
    if let blocked = PlanDelivery.decide(supported: supported, activated: supported && s.activationState == .activated,
                                         paired: supported && s.isPaired, appInstalled: supported && s.isWatchAppInstalled) {
      if blocked == .notActivated { onNeedsActivation() }
      return blocked
    }
    do {
      try s.updateApplicationContext(SessionSourceCodec.planContext(plan))
      return .sent
    } catch {
      return .failed
    }
  }
}
#endif
