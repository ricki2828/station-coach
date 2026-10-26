import CoachKit
import SwiftUI

/// Everything the three onboarding screens show or write. D wires `watchAppInstalled` from `WCSession`
/// and persists `division` / `targetSeconds` to `setup.division` / `setup.target`, the same keys as Setup.
public struct OnboardingModel: Equatable {
  public var division: Division
  public var targetSeconds: Int
  public var watchAppInstalled: Bool

  public init(division: Division = .openMen, targetSeconds: Int = 5400, watchAppInstalled: Bool = true) {
    self.division = division
    self.targetSeconds = targetSeconds
    self.watchAppInstalled = watchAppInstalled
  }
}

/// Paper page with a statement, body, and pinned footer; shared frame for the three screens.
private struct OnboardingPage<Top: View, Content: View, Footer: View>: View {
  let top: Top
  let content: Content
  let footer: Footer

  init(@ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.top = top()
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      top.frame(minHeight: 44, alignment: .topLeading)
      Spacer(minLength: 24)
      content
      Spacer(minLength: 32)
      footer
    }
    .padding(.horizontal, 24)
    .padding(.top, 24)
    .padding(.bottom, 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PhoneTheme.paper)
  }
}

private struct SkipRow: View {
  let onSkip: () -> Void
  var body: some View {
    HStack {
      Spacer()
      TextLinkButton("Skip", action: onSkip)
    }
  }
}

private let bodyFont = Font.system(size: 19, weight: .semibold)

/// 1 of 3: the promise.
public struct OnboardingIntroScreen: View {
  var onContinue: () -> Void
  public init(onContinue: @escaping () -> Void = {}) { self.onContinue = onContinue }

  public var body: some View {
    OnboardingPage(top: { Wordmark(size: 34) }, content: {
      VStack(alignment: .leading, spacing: 18) {
        Text("Run the race before race day.").phoneStatement(size: 56).foregroundStyle(PhoneTheme.inkText)
          .fixedSize(horizontal: false, vertical: true)
        Text("Your watch times every run and station, talks you through it, and shows where the time went.")
          .font(bodyFont).foregroundStyle(PhoneTheme.muted).fixedSize(horizontal: false, vertical: true)
      }
    }, footer: {
      PrimaryButton("Continue", action: onContinue)
    })
  }
}

private struct RaceChoice: View {
  let title: String
  let selected: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 17, weight: .heavy))
        .foregroundStyle(selected ? Theme.bone : PhoneTheme.inkText)
        .frame(maxWidth: .infinity, minHeight: PhoneTheme.buttonHeight)
        .background(selected ? PhoneTheme.inkText : PhoneTheme.card, in: RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(selected ? PhoneTheme.inkText : PhoneTheme.hairline, lineWidth: selected ? 2 : 1))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct RaceStepButton: View {
  let symbol: String
  let label: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(symbol).font(.system(size: 28, weight: .heavy)).foregroundStyle(PhoneTheme.inkText)
        .frame(width: 56, height: 56)
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.buttonRadius).stroke(PhoneTheme.inkText, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// 2 of 3: division and target. Skip is available.
public struct OnboardingRaceScreen: View {
  let model: OnboardingModel
  var onDivision: (Division) -> Void
  var onTargetStep: (Int) -> Void
  var onContinue: () -> Void
  var onSkip: () -> Void

  public init(model: OnboardingModel, onDivision: @escaping (Division) -> Void = { _ in }, onTargetStep: @escaping (Int) -> Void = { _ in },
              onContinue: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}) {
    self.model = model
    self.onDivision = onDivision
    self.onTargetStep = onTargetStep
    self.onContinue = onContinue
    self.onSkip = onSkip
  }

  public var body: some View {
    OnboardingPage(top: { SkipRow(onSkip: onSkip) }, content: {
      VStack(alignment: .leading, spacing: 20) {
        Text("Your race").phoneStatement(size: 56).foregroundStyle(PhoneTheme.inkText)
        VStack(alignment: .leading, spacing: 8) {
          Text("Division").phoneKicker()
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.prefix(2))) { d in RaceChoice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.suffix(2))) { d in RaceChoice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Target finish").phoneKicker()
          HStack(spacing: 10) {
            RaceStepButton(symbol: "\u{2212}", label: "Five minutes less") { onTargetStep(-300) }
            Text(Fmt.clock(model.targetSeconds)).phoneHero(size: 56).foregroundStyle(PhoneTheme.inkText)
              .frame(maxWidth: .infinity).lineLimit(1).minimumScaleFactor(0.7)
              .accessibilityLabel("Target finish \(Fmt.clock(model.targetSeconds))")
            RaceStepButton(symbol: "+", label: "Five minutes more") { onTargetStep(300) }
          }
        }
        Text("The target is a guess for now. The plan splits it across all 16 parts.")
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.muted).fixedSize(horizontal: false, vertical: true)
      }
    }, footer: {
      PrimaryButton("Continue", action: onContinue)
    })
  }
}

/// 3 of 3: how to use the watch, and whether the watch app is there. Skip is available.
public struct OnboardingWatchScreen: View {
  let model: OnboardingModel
  var onBuild: () -> Void
  var onSkip: () -> Void

  public init(model: OnboardingModel, onBuild: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}) {
    self.model = model
    self.onBuild = onBuild
    self.onSkip = onSkip
  }

  private static let rows: [(Activity, String)] = [
    (.skierg, "Tap NEXT when you finish each run or station."),
    (.sledPush, "Hold the screen for Undo and End."),
    (.burpeeBroadJump, "Cues play in your AirPods. No AirPods: the watch taps your wrist."),
  ]

  public var body: some View {
    OnboardingPage(top: { SkipRow(onSkip: onSkip) }, content: {
      VStack(alignment: .leading, spacing: 20) {
        Text("On the watch").phoneStatement(size: 56).foregroundStyle(PhoneTheme.inkText)
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top, spacing: 14) {
              Circle().fill(PhoneTheme.stationColor(row.0)).frame(width: 18, height: 18).padding(.top, 4)
              Text(row.1).font(bodyFont).foregroundStyle(PhoneTheme.inkText).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        PhoneCard {
          if model.watchAppInstalled {
            HStack(spacing: 10) {
              Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(PhoneTheme.inkText)
              Text("Watch app installed").font(.system(size: 17, weight: .heavy)).foregroundStyle(PhoneTheme.inkText)
            }
          } else {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "exclamationmark.circle.fill").font(.system(size: 22)).foregroundStyle(PhoneTheme.amberText)
              Text("Install on your watch: Watch app \u{2192} Available apps")
                .font(.system(size: 17, weight: .heavy)).foregroundStyle(PhoneTheme.amberText).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }, footer: {
      PrimaryButton("Build my first session", action: onBuild)
    })
  }
}

/// The whole flow. Pages advance in place; `onFinish` fires from "Build my first session" and from Skip.
public struct OnboardingFlow: View {
  @State private var page = 0
  @Binding var model: OnboardingModel
  let onFinish: () -> Void

  public init(model: Binding<OnboardingModel>, onFinish: @escaping () -> Void) {
    self._model = model
    self.onFinish = onFinish
  }

  public var body: some View {
    Group {
      switch page {
      case 0: OnboardingIntroScreen { page = 1 }
      case 1:
        OnboardingRaceScreen(model: model, onDivision: { model.division = $0 },
                             onTargetStep: { model.targetSeconds = min(12000, max(2400, model.targetSeconds + $0)) },
                             onContinue: { page = 2 }, onSkip: onFinish)
      default: OnboardingWatchScreen(model: model, onBuild: onFinish, onSkip: onFinish)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: page)
  }
}
