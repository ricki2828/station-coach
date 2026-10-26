import Foundation

/// What the athlete chose for the Monday summary notification.
public enum NotifyChoice: String, Equatable {
  /// Never asked, or not answered.
  case undecided
  case yes
  /// "No thanks", or switched off in the Plan tab.
  case no
}

/// What iOS currently allows for this app's notifications. Read again on every foreground: it can change in iOS Settings.
public enum NotifyAuthorization: Equatable {
  case notDetermined, denied, authorized
}

/// The Monday notification setting as one value: the athlete's choice and the system's answer, kept apart so that
/// declining the iOS prompt is never a permanent "no", and enabling notifications later in iOS Settings starts it again.
public struct NotifySettingState: Equatable {
  public let choice: NotifyChoice
  public let auth: NotifyAuthorization

  public init(choice: NotifyChoice, auth: NotifyAuthorization) {
    self.choice = choice
    self.auth = auth
  }

  /// A notification is scheduled only when the athlete wants one and the system allows it.
  public var isScheduling: Bool { choice == .yes && auth == .authorized }
  /// What the Plan switch shows.
  public var switchOn: Bool { isScheduling }
  /// Wanted, but the system says no: the Plan tab points at iOS Settings.
  public var blockedBySystem: Bool { choice == .yes && auth == .denied }
  /// The one-time card on the weekly summary: only before an answer, and not once iOS has already said no.
  public var showsOptInCard: Bool { choice == .undecided && auth != .denied }

  public enum Action: Equatable {
    /// Show the iOS permission prompt.
    case askSystem
    /// iOS already said no; only Settings can change it.
    case openSystemSettings
    case nothing
  }

  /// Turning it on records the wish first. What else is needed depends on what iOS allows.
  public func turnedOn() -> (state: NotifySettingState, action: Action) {
    let next = NotifySettingState(choice: .yes, auth: auth)
    switch auth {
    case .notDetermined: return (next, .askSystem)
    case .denied: return (next, .openSystemSettings)
    case .authorized: return (next, .nothing)
    }
  }

  /// Switching off is the athlete's own answer.
  public func turnedOff() -> NotifySettingState { NotifySettingState(choice: .no, auth: auth) }

  /// The iOS prompt was answered. A refusal leaves the wish as it was (so granting later in Settings works) and only
  /// changes what iOS allows.
  public func afterPrompt(granted: Bool) -> NotifySettingState {
    NotifySettingState(choice: choice, auth: granted ? .authorized : .denied)
  }

  /// "No thanks" on the one-time card.
  public func declinedCard() -> NotifySettingState { NotifySettingState(choice: .no, auth: auth) }
}
