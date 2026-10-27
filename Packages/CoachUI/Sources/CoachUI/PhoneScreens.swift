import CoachKit
import SwiftUI

// MARK: Setup

public enum SendState: Equatable {
  case idle
  case sending(watchName: String)
  case sent
  /// The watch app is not installed.
  case watchAppMissing
  /// The watch is not reachable right now.
  case failed
}

public struct SetupModel: Equatable {
  public var division: Division
  public var targetSeconds: Int
  public var type: SessionType
  /// Reps per round of the wall-ball focus session.
  public var wallBallReps: Int
  public var send: SendState
  /// The last comparable session, or why there is none. Filled by the host from History.
  public var ghost: GhostOffer
  /// "Race against: last session" chosen. Off by default: the plan is the reference (it is tied to the race target).
  public var useGhost: Bool

  public init(division: Division = .openMen, targetSeconds: Int = 5400, type: SessionType = .fullSim,
              wallBallReps: Int = PlanBuilder.defaultFocusReps, send: SendState = .idle,
              ghost: GhostOffer = .none, useGhost: Bool = false) {
    self.division = division
    self.targetSeconds = targetSeconds
    self.type = type
    self.wallBallReps = wallBallReps
    self.send = send
    self.ghost = ghost
    self.useGhost = useGhost
  }

  /// The plan from the targets alone; the ghost offer is made for this one.
  public var basePlan: SessionPlan { PlanBuilder.build(division: division, target: targetSeconds, type: type, wallBallReps: wallBallReps) }

  /// What goes to the watch: the base plan, carrying the ghost's splits when the ghost is chosen and available.
  public var plan: SessionPlan { Ghost.plan(basePlan, racing: ghost, race: useGhost) }
}

/// Bars whose widths follow their weights. Explicit widths: layout priorities do not do this.
struct ProportionalStrip: View {
  let items: [(Color, Double)]
  let height: CGFloat
  var gap: CGFloat = 3

  var body: some View {
    GeometryReader { geo in
      let total = max(items.reduce(0) { $0 + $1.1 }, 1)
      let room = geo.size.width - gap * CGFloat(max(items.count - 1, 0))
      HStack(spacing: gap) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          RoundedRectangle(cornerRadius: 4).fill(item.0).frame(width: max(2, room * CGFloat(item.1 / total)), height: height)
        }
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}

struct Choice: View {
  let title: String
  let selected: Bool
  var fill: Color = PhoneTheme.inkText
  var text: Color = Theme.bone
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(selected ? text : PhoneTheme.inkText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(selected ? fill : PhoneTheme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.clear : PhoneTheme.hairline, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Plan tab: division, target, session, the estimated split, send to watch. Light, same controls as before.
public struct SetupScreen: View {
  let model: SetupModel
  var onDivision: (Division) -> Void = { _ in }
  var onTargetStep: (Int) -> Void = { _ in }
  var onType: (SessionType) -> Void = { _ in }
  var onWallBallReps: (Int) -> Void = { _ in }
  var onReference: (Bool) -> Void = { _ in }
  var onSend: () -> Void = {}
  let notify: NotifySettingState?
  let onNotifyToggle: (Bool) -> Void

  /// `notify` non-nil shows the Monday summary switch at the foot of the tab.
  public init(model: SetupModel, notify: NotifySettingState? = nil, onNotifyToggle: @escaping (Bool) -> Void = { _ in },
              onDivision: @escaping (Division) -> Void = { _ in }, onTargetStep: @escaping (Int) -> Void = { _ in },
              onType: @escaping (SessionType) -> Void = { _ in }, onWallBallReps: @escaping (Int) -> Void = { _ in },
              onReference: @escaping (Bool) -> Void = { _ in }, onSend: @escaping () -> Void = {}) {
    self.model = model
    self.notify = notify
    self.onNotifyToggle = onNotifyToggle
    self.onDivision = onDivision
    self.onTargetStep = onTargetStep
    self.onType = onType
    self.onWallBallReps = onWallBallReps
    self.onReference = onReference
    self.onSend = onSend
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Build today's session").phoneStatement(size: 34).foregroundStyle(PhoneTheme.inkText)
        .fixedSize(horizontal: false, vertical: true)
      PhoneCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("Division").phoneKicker()
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.prefix(2))) { d in Choice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.suffix(2))) { d in Choice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
        }
      }
      PhoneCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("Target finish").phoneKicker()
          HStack(spacing: 10) {
            stepButton("\u{2212}", "Five minutes less") { onTargetStep(-300) }
            Text(Fmt.clock(model.targetSeconds)).phoneHero(size: 48).foregroundStyle(PhoneTheme.inkText).frame(maxWidth: .infinity)
              .accessibilityLabel("Target finish \(Fmt.clock(model.targetSeconds))")
            stepButton("+", "Five minutes more") { onTargetStep(300) }
          }
        }
      }
      PhoneCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("Session").phoneKicker()
          ForEach(SessionType.allCases) { t in
            Choice(title: "\(t.title) \u{00B7} \(t.detail(wallBallReps: model.wallBallReps))", selected: model.type == t,
                   fill: PhoneTheme.sessionColor(t), text: PhoneTheme.sessionText(t)) { onType(t) }
          }
          if model.type == .wallBallFocus {
            Text("Wall balls per round").phoneKicker().padding(.top, 4)
            HStack(spacing: 8) {
              ForEach(PlanBuilder.focusRepOptions, id: \.self) { n in
                Choice(title: "\(n)", selected: model.wallBallReps == n) { onWallBallReps(n) }
              }
            }
          }
        }
      }
      referenceCard
      splitSummary
      sendArea
      if let notify { MondaySummaryCard(state: notify, onToggle: onNotifyToggle) }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(PhoneTheme.paper)
  }

  private func stepButton(_ symbol: String, _ a11y: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(symbol).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.bone)
        .frame(width: 52, height: 52).background(PhoneTheme.inkText, in: Circle())
    }.buttonStyle(.plain).accessibilityLabel(a11y)
  }

  /// "Race against": the plan (default) or the last comparable session. One reference for the whole session.
  private var referenceCard: some View {
    let racing = model.useGhost && model.ghost.available
    return PhoneCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Race against").phoneKicker()
        referenceOption(title: "Plan", sub: "Targets from \(Fmt.clock(model.basePlan.plannedSeconds))", selected: !racing, enabled: true) { onReference(false) }
        referenceOption(title: model.ghost.title, sub: model.ghost.sub, selected: racing, enabled: model.ghost.available) { onReference(true) }
      }
    }
  }

  private func referenceOption(title: String, sub: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(selected ? Theme.bone : PhoneTheme.inkText)
        Text(sub).font(.system(size: 13)).foregroundStyle(selected ? Theme.bone.opacity(0.85) : PhoneTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(selected ? PhoneTheme.inkText : PhoneTheme.paper, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.clear : PhoneTheme.hairline, lineWidth: 1))
      .opacity(enabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var splitSummary: some View {
    let plan = model.plan
    let run = plan.steps.first { $0.isRun }?.targetSeconds ?? 0
    return PhoneCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Plan").phoneKicker()
          Text("ESTIMATE").font(.system(size: 11, weight: .heavy)).foregroundStyle(PhoneTheme.inkText)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.amber, in: Capsule())
        }
        Text("\(plan.steps.filter(\.isRun).count) runs at \(Fmt.clock(run)) including transitions")
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
        ProportionalStrip(items: plan.steps.filter { !$0.isRun }.map { (PhoneTheme.stationColor($0.activity), Double($0.targetSeconds)) }, height: 14)
        Text("Total \(Fmt.clock(plan.plannedSeconds)). Default split: runs about half, stations by typical shares.")
          .font(.system(size: 13)).foregroundStyle(PhoneTheme.muted)
      }
    }
  }

  private var sendArea: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: onSend) {
        HStack(spacing: 8) {
          if case .sending = model.send { Spinner(color: Theme.bone) }
          Text(sendTitle).font(.system(size: 17, weight: .heavy))
        }
        .foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .background(PhoneTheme.inkText, in: RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius))
      }.buttonStyle(.plain)
      switch model.send {
      case .idle: EmptyView()
      case .sending(let name): Text("Sending plan to \(name)\u{2026}").font(.system(size: 15)).foregroundStyle(PhoneTheme.inkText)
      case .sent: Text("Plan on your watch").font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
      case .watchAppMissing:
        Text("Install on your watch: Watch app \u{2192} Available apps").font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.amberText)
      case .failed:
        Text("Watch not reachable. Open the app on your watch, then Send again").font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.amberText)
      }
    }
  }

  private var sendTitle: String {
    switch model.send {
    case .sent: return "Sent"
    case .sending: return "Sending"
    default: return "Send to watch"
    }
  }
}

// MARK: Sync notice

/// Shown above History when the newest finished session has not arrived.
public struct InstallWatchCard: View {
  let onDismiss: () -> Void
  public init(onDismiss: @escaping () -> Void = {}) { self.onDismiss = onDismiss }
  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 6) {
        Text("Install the watch app").phoneKicker(color: PhoneTheme.amberText)
        Text("Open the Watch app on your iPhone, find Station Coach and tap Install.")
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
        TextLinkButton("Dismiss", action: onDismiss)
      }
    }
  }
}

/// Sync-failed card.
public struct SyncFailedCard: View {
  public init() {}
  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 6) {
        Text("Not received yet").phoneKicker(color: PhoneTheme.amberText)
        Text("On your watch: Home \u{2192} Send unsent").font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
      }
    }
  }
}

/// Plan-tab footer: the Monday summary notification, off until the athlete turns it on. A refusal in iOS shows here, with the way back.
public struct MondaySummaryCard: View {
  let state: NotifySettingState
  let onToggle: (Bool) -> Void

  public init(state: NotifySettingState, onToggle: @escaping (Bool) -> Void) {
    self.state = state
    self.onToggle = onToggle
  }

  public var body: some View {
    PhoneCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Monday summary").phoneKicker()
            Text("One notification a week, nothing else.").scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          // Drawn, not Toggle: ImageRenderer cannot render the UIKit-backed switch.
          Button { onToggle(!state.switchOn) } label: {
            ZStack(alignment: state.switchOn ? .trailing : .leading) {
              Capsule().fill(state.switchOn ? PhoneTheme.inkText : PhoneTheme.hairline).frame(width: 56, height: 34)
                .overlay(Capsule().stroke(state.switchOn ? PhoneTheme.inkText : PhoneTheme.muted, lineWidth: 1.5))
              Circle().fill(Color.white).frame(width: 28, height: 28).padding(3)
            }
            .frame(minWidth: 56, minHeight: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Monday summary")
          .accessibilityValue(state.switchOn ? "On" : "Off")
        }
        if state.blockedBySystem {
          Text("Notifications are off for Station Coach in iOS Settings. Turn them on there and the summary starts by itself.")
            .scaledFont(15, .semibold).foregroundStyle(PhoneTheme.amberText).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
