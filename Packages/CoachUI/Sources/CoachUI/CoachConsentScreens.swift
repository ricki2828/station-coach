import CoachKit
import SwiftUI

/// Copy and rows for the optional AI coach. Every line the athlete reads before turning it on lives here, so the text
/// that is reviewed is the text that ships. Consent version 1. The privacy-policy link and the lawyer's wording are open items.
public enum CoachConsentCopy {
  public static let offerKicker = "AI coach \u{00B7} optional"
  public static let offerStatement = "A debrief after every sim"
  public static let offerBody = "Turn this on and your session times go to our coach service. An AI model writes one short debrief: where the time went and what to train next."
  public static let seeWhatsSent = "See exactly what\u{2019}s sent"
  public static let notNow = "Not now"

  public static let factsStatement = "What leaves your phone"
  public static let neverSentKicker = "Never sent"
  public static let neverSent = [
    "Heart rate",
    "Motion or sensor recordings",
    "Location",
    "Your name, email or Apple ID",
    "Anything from Apple Health",
    "Your age or weight",
    "Notes or messages (there is no free text)",
  ]

  public static let installIdLine = "A random ID for this app, so the coach remembers your past sessions. Not your name or Apple ID."

  /// D10: the no-retention sentence ships only once zero-retention is confirmed on the provider account.
  public static func whoSees(zeroRetentionConfirmed: Bool) -> String {
    let base = "Our coach service passes these facts to OpenRouter, a routing service, and to the AI model that writes the reply (Anthropic\u{2019}s Claude)."
    return base + (zeroRetentionConfirmed ? " Neither keeps them or trains on them." : " Either may keep them for up to 30 days.")
  }

  public static let howLong = "We keep your sessions for 30 days so the coach can compare them, then delete them. Turn the coach off to delete them now."
  public static let turnOn = "Turn on AI coach"
  public static let turningOn = "Turning on\u{2026}"
  public static let onFailed = "Couldn\u{2019}t reach our server. Your sessions weren\u{2019}t sent. Try again."

  public static let turnOffRow = "Turn off and delete my data"
  public static let turnOffConfirm = "Turn off the AI coach? We delete the sessions we hold for you."
  public static let resetNotice = "AI coach was reset after 30 days without use. Your earlier debriefs are kept. Turn it on again if you want more."
  public static let revokedPending = "AI coach is off. We\u{2019}ll delete your data as soon as we can reach our server."

  public static let needsUpdate = "Update the app to keep the AI coach. Nothing more is sent until you do."
  public static let reconsentStatement = "What\u{2019}s sent has changed"
  public static let keepItOn = "Keep it on"
  public static let turnOff = "Turn off"

  public static let debriefQueued = "Debrief waiting for a connection."
  public static let debriefLoading = "Coach is reading your session\u{2026}"
  public static let debriefAI = "Written by AI. It can be wrong."
  public static let debriefError = "Couldn\u{2019}t get a debrief. We\u{2019}ll try again next time you open the app."
  public static let debriefCap = "That\u{2019}s today\u{2019}s debriefs. More tomorrow."

  public static func footer(version: Int) -> String { "Consent version \(version) \u{00B7} Privacy policy" }
  public static func onSince(_ since: String) -> String { "AI coach is on since \(CoachDay.short(since))." }
  public static func revoked(deleted: Int) -> String {
    "AI coach is off. We deleted \(deleted) \(deleted == 1 ? "session" : "sessions")."
  }
}

enum CoachDay {
  private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  /// "2026-10-27" -> "27 Oct". Anything else comes back unchanged.
  static func short(_ day: String) -> String {
    let p = day.split(separator: "-")
    guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m) else { return day }
    return "\(d) \(months[m - 1])"
  }
}

/// One line of "what leaves your phone": what it is, and this athlete's own value.
public struct CoachFactRow: Equatable, Identifiable {
  public let id: String
  public let label: String
  public let value: String
  public var isNew = false

  /// The whole payload, as the athlete would see it for one session. Matches `CoachFacts` field for field.
  public static func rows(for f: CoachFacts) -> [CoachFactRow] {
    var out: [CoachFactRow] = [
      CoachFactRow(id: "installId", label: "Install ID", value: CoachConsentCopy.installIdLine),
      CoachFactRow(id: "date", label: "The day of the session", value: CoachDay.short(f.date)),
      CoachFactRow(id: "sessionType", label: "Session type", value: f.sessionType.title),
      CoachFactRow(id: "division", label: "Division", value: f.division.title),
      CoachFactRow(id: "target", label: "Your target", value: Fmt.clock(f.raceTargetSeconds)),
      CoachFactRow(id: "total", label: "Total", value: Fmt.clock(f.totalSeconds) + (f.early ? ", stopped early" : "")),
      CoachFactRow(id: "steps", label: "Each run and station: target and actual time", value: "\(f.steps.count) steps"),
    ]
    if let w = f.wallBalls {
      out.append(CoachFactRow(id: "wallBalls", label: "Wall balls: reps, no-reps, sets and rests",
                              value: "\(w.reps) reps, \(w.noReps) no-reps, \(w.setSizes.count) sets"))
    }
    if let fade = f.fadeSeconds { out.append(CoachFactRow(id: "fade", label: "Run fade", value: "\(fade)\u{00A0}s")) }
    if let d = f.referenceDeltaSeconds, let r = f.reference {
      out.append(CoachFactRow(id: "reference", label: "How you did against your \(r == .plan ? "plan" : "last sim")", value: Fmt.delta(d)))
    }
    return out
  }

  /// The sample the "Example" screen shows before the athlete has a session: a half sim.
  public static var exampleFacts: CoachFacts {
    CoachFacts.make(from: HistorySamples.record("example", type: .halfSim, startDay: 0, fade: 27, stationExtra: [.sledPush: 20]).result,
                    installId: "00000000-0000-0000-0000-000000000000", consentVersion: CoachConsent.currentVersion)
  }
}

private struct CoachPage<Content: View>: View {
  let content: Content
  init(@ViewBuilder _ content: () -> Content) { self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) { content }
      .padding(.horizontal, 20).padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(PhoneTheme.paper)
  }
}

/// Screen 1: the offer card on the session detail (after the second synced session) and the Settings row.
public struct CoachOfferCard: View {
  let onSee: () -> Void
  let onNotNow: () -> Void
  public init(onSee: @escaping () -> Void = {}, onNotNow: @escaping () -> Void = {}) {
    self.onSee = onSee
    self.onNotNow = onNotNow
  }

  public var body: some View {
    CoachPage {
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          Text(CoachConsentCopy.offerKicker).scaledKicker()
          Text(CoachConsentCopy.offerStatement).scaledStatement(size: 34).foregroundStyle(PhoneTheme.inkText)
            .fixedSize(horizontal: false, vertical: true)
          Text(CoachConsentCopy.offerBody).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText)
            .fixedSize(horizontal: false, vertical: true)
          CoachPrimaryButton(CoachConsentCopy.seeWhatsSent, action: onSee)
          CoachLinkButton(CoachConsentCopy.notNow, action: onNotNow)
        }
      }
    }
  }
}

public enum CoachFactsMode: Equatable {
  /// This athlete's last session.
  case lastSession
  /// A sample half sim, labelled "Example", for Settings before any session exists.
  case example
  case turningOn
  case failed
}

/// Screen 2: exactly what leaves the phone, what never does, who sees it, and for how long.
/// Wrap in a ScrollView at the call site; the catalog renders it at full height.
public struct CoachFactsScreen: View {
  let facts: CoachFacts
  let mode: CoachFactsMode
  let zeroRetentionConfirmed: Bool
  let onTurnOn: () -> Void
  let onNotNow: () -> Void

  public init(facts: CoachFacts, mode: CoachFactsMode = .lastSession, zeroRetentionConfirmed: Bool = false,
              onTurnOn: @escaping () -> Void = {}, onNotNow: @escaping () -> Void = {}) {
    self.facts = facts
    self.mode = mode
    self.zeroRetentionConfirmed = zeroRetentionConfirmed
    self.onTurnOn = onTurnOn
    self.onNotNow = onNotNow
  }

  public var body: some View {
    CoachPage {
      Text(CoachConsentCopy.factsStatement).scaledStatement(size: 40).foregroundStyle(PhoneTheme.inkText)
        .fixedSize(horizontal: false, vertical: true)
      if mode == .example { Text("Example").scaledKicker() }
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(CoachFactRow.rows(for: facts)) { CoachFactRowView(row: $0) }
        }
      }
      PhoneCard {
        VStack(alignment: .leading, spacing: 8) {
          Text(CoachConsentCopy.neverSentKicker).scaledKicker()
          ForEach(CoachConsentCopy.neverSent, id: \.self) { item in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text("\u{2715}").scaledFont(15, .heavy).foregroundStyle(PhoneTheme.inkText).accessibilityHidden(true)
              Text(item).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Never sent: \(item)")
          }
        }
      }
      block("Who sees it", CoachConsentCopy.whoSees(zeroRetentionConfirmed: zeroRetentionConfirmed))
      block("How long", CoachConsentCopy.howLong)
      Text(CoachConsentCopy.footer(version: CoachConsent.currentVersion)).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
      if mode == .failed {
        Text(CoachConsentCopy.onFailed).scaledFont(15, .heavy).foregroundStyle(PhoneTheme.amberText).fixedSize(horizontal: false, vertical: true)
      }
      CoachPrimaryButton(mode == .turningOn ? CoachConsentCopy.turningOn : CoachConsentCopy.turnOn, action: onTurnOn)
        .opacity(mode == .turningOn ? 0.6 : 1).disabled(mode == .turningOn)
      CoachLinkButton(CoachConsentCopy.notNow, action: onNotNow)
    }
  }

  private func block(_ kicker: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(kicker).scaledKicker()
      Text(text).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct CoachFactRowView: View {
  let row: CoachFactRow
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(row.label).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted).fixedSize(horizontal: false, vertical: true)
        if row.isNew {
          Text("New").scaledFont(11, .heavy).textCase(.uppercase).foregroundStyle(PhoneTheme.inkText)
            .padding(.horizontal, 7).padding(.vertical, 2).background(PhoneTheme.best, in: Capsule())
        }
      }
      Text(row.value).scaledFont(row.id == "installId" ? 15 : 19, row.id == "installId" ? .semibold : .heavy)
        .foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Screens 3 and 4: the Settings row once the coach is on, and what the athlete sees after turning it off.
public enum CoachSettingsState: Equatable {
  case on(since: String)
  case revoked(deleted: Int)
  case revokedPending
  /// The service forgot this install after 30 idle days.
  case reset
  /// The service wants a consent this build cannot show: only turning off is offered.
  case needsUpdate
}

public struct CoachSettingsCard: View {
  let state: CoachSettingsState
  let onWhatsSent: () -> Void
  let onTurnOff: () -> Void
  public init(state: CoachSettingsState, onWhatsSent: @escaping () -> Void = {}, onTurnOff: @escaping () -> Void = {}) {
    self.state = state
    self.onWhatsSent = onWhatsSent
    self.onTurnOff = onTurnOff
  }

  public var body: some View {
    CoachPage {
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("AI coach").scaledKicker()
          switch state {
          case .on(let since):
            Text(CoachConsentCopy.onSince(since)).scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
            CoachLinkButton("What\u{2019}s sent", action: onWhatsSent)
            Button(action: onTurnOff) {
              Text(CoachConsentCopy.turnOffRow).underline().scaledFont(15, .semibold).foregroundStyle(PhoneTheme.amberText)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
          case .revoked(let n):
            Text(CoachConsentCopy.revoked(deleted: n)).scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
          case .needsUpdate:
            Text(CoachConsentCopy.needsUpdate).scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
            Button(action: onTurnOff) {
              Text(CoachConsentCopy.turnOffRow).underline().scaledFont(15, .semibold).foregroundStyle(PhoneTheme.amberText)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
          case .reset:
            Text(CoachConsentCopy.resetNotice).scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
          case .revokedPending:
            Text(CoachConsentCopy.revokedPending).scaledFont(19, .heavy).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

/// Screen 5: the consent text changed. Nothing is sent until this is answered.
public struct CoachReconsentScreen: View {
  let changed: [CoachFactRow]
  let onKeep: () -> Void
  let onTurnOff: () -> Void
  public init(changed: [CoachFactRow], onKeep: @escaping () -> Void = {}, onTurnOff: @escaping () -> Void = {}) {
    self.changed = changed
    self.onKeep = onKeep
    self.onTurnOff = onTurnOff
  }

  public var body: some View {
    CoachPage {
      Text(CoachConsentCopy.reconsentStatement).scaledStatement(size: 40).foregroundStyle(PhoneTheme.inkText)
        .fixedSize(horizontal: false, vertical: true)
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(changed) { row in
            CoachFactRowView(row: CoachFactRow(id: row.id, label: row.label, value: row.value, isNew: true))
          }
        }
      }
      Text("Nothing is sent until you answer.").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
      CoachPrimaryButton(CoachConsentCopy.keepItOn, action: onKeep)
      CoachSecondaryButton(CoachConsentCopy.turnOff, action: onTurnOff)
    }
  }
}

/// How a debrief looks on the session detail.
public enum DebriefDisplay: Equatable {
  case queued
  case loading
  case reply(String)
  case error
  case cap

  /// `nil` when the athlete has no debrief to show (coach off, or not asked yet).
  public init?(_ state: DebriefState) {
    switch state {
    case .none: return nil
    case .queued: self = .queued
    case .reply(let r): self = .reply(r)
    case .error: self = .error
    case .cap: self = .cap
    }
  }
}

public struct DebriefCard: View {
  let display: DebriefDisplay
  public init(display: DebriefDisplay) { self.display = display }

  public var body: some View {
    CoachPage {
      PhoneCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("Coach").scaledKicker()
          switch display {
          case .queued: line(CoachConsentCopy.debriefQueued)
          case .loading: line(CoachConsentCopy.debriefLoading)
          case .reply(let text):
            Text(text).scaledFont(19, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
            Text(CoachConsentCopy.debriefAI).scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
          case .error: line(CoachConsentCopy.debriefError)
          case .cap: line(CoachConsentCopy.debriefCap)
          }
        }
      }
    }
  }

  private func line(_ text: String) -> some View {
    Text(text).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
  }
}

// Buttons that follow Dynamic Type (the shared ones use fixed sizes, which stayed small at the largest text size).
private struct CoachPrimaryButton: View {
  let title: String
  let action: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title).scaledFont(17, .heavy).foregroundStyle(Theme.bone).multilineTextAlignment(.center)
        .padding(.vertical, 12).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .background(PhoneTheme.inkText, in: RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius))
    }
    .buttonStyle(.plain)
  }
}

private struct CoachSecondaryButton: View {
  let title: String
  let action: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title).scaledFont(17, .heavy).foregroundStyle(PhoneTheme.inkText).multilineTextAlignment(.center)
        .padding(.vertical, 12).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(PhoneTheme.inkText, lineWidth: 2))
    }
    .buttonStyle(.plain)
  }
}

private struct CoachLinkButton: View {
  let title: String
  let action: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title).underline().scaledFont(15, .semibold).foregroundStyle(PhoneTheme.inkText)
        .frame(minHeight: 44, alignment: .leading)
    }
    .buttonStyle(.plain)
  }
}
