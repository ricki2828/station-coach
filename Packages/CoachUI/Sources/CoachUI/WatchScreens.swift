import CoachKit
import SwiftUI

/// Pill that holds the session delta: bone when level or ahead, amber when behind. Never red.
struct DeltaBand: View {
  let seconds: Int

  var body: some View {
    Text(Fmt.delta(seconds))
      .font(Theme.number(Theme.Size.floor))
      .condensed()
      .foregroundStyle(seconds > 0 ? Theme.amber : Theme.bone)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .padding(.horizontal, 8)
      .background(Theme.ink.opacity(0.88), in: Capsule())
      .accessibilityLabel(seconds == 0 ? "On plan" : "\(Fmt.gap(seconds)) \(seconds > 0 ? "behind" : "ahead of") plan")
  }
}

struct HeartChip: View {
  let bpm: Int

  var body: some View {
    Text("\(bpm)")
      .font(.system(size: 15, weight: .bold))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Theme.zone(Palette.zone(bpm: bpm)), in: Capsule())
      .accessibilityLabel("Heart rate \(bpm)")
  }
}

/// Plain arc spinner: `ProgressView` is a UIKit view that ImageRenderer cannot draw.
struct Spinner: View {
  var color: Color
  @State private var turning = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle().trim(from: 0, to: 0.7)
      .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
      .frame(width: 28, height: 28)
      .rotationEffect(.degrees(turning ? 360 : 0))
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
      }
      .accessibilityLabel("Loading")
  }
}

struct Toast: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(Theme.bone)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Theme.ink.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// The M1 alarm, restyled: red, loud, with the way out.
public struct AlarmBanner: View {
  let text: String
  var action: String = "OK"
  var onAction: () -> Void = {}

  public init(text: String, action: String = "OK", onAction: @escaping () -> Void = {}) {
    self.text = text
    self.action = action
    self.onAction = onAction
  }

  public var body: some View {
    VStack(spacing: 2) {
      Text("RECORDING AT RISK").font(.system(size: 15, weight: .heavy))
      Text(text).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
      Button(action, action: onAction).font(.system(size: 15, weight: .bold))
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity)
    .padding(6)
    .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
  }
}

struct NextButton: View {
  let activity: Activity
  let isLast: Bool
  let action: () -> Void

  var body: some View {
    let button = Button(action: action) {
      Text(isLast ? "FINISH" : "NEXT")
        .font(.system(size: 22, weight: .heavy))
        .foregroundStyle(Theme.background(activity))
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Theme.text(activity), in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isLast ? "Finish session" : "Next")
    #if os(watchOS)
    if #available(watchOS 11.0, *) {
      button.handGestureShortcut(.primaryAction)
    } else {
      button
    }
    #else
    button
    #endif
  }
}

struct StepperButton: View {
  let symbol: String
  let label: String
  let pulse: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(symbol)
        .font(.system(size: 30, weight: .heavy))
        .foregroundStyle(Theme.bone)
        .frame(width: 44, height: 44)
        .background(Theme.ink.opacity(0.88), in: Circle())
        .overlay(Circle().stroke(Theme.bone, lineWidth: pulse ? 3 : 0))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// Run, time-based station and rep station: one dominant number each. Max three items besides the delta.
public struct CoachStepScreen: View {
  let model: StepScreenModel
  var onNext: () -> Void = {}
  var onPlus: () -> Void = {}
  var onMinus: () -> Void = {}
  /// M1's "didn't hear" control, pinned beside NEXT on every coach screen. Nil hides it.
  var onMissed: (() -> Void)?
  var onAlarm: () -> Void = {}

  public init(model: StepScreenModel, onNext: @escaping () -> Void = {}, onPlus: @escaping () -> Void = {}, onMinus: @escaping () -> Void = {}, onMissed: (() -> Void)? = nil, onAlarm: @escaping () -> Void = {}) {
    self.onMissed = onMissed
    self.onAlarm = onAlarm
    self.model = model
    self.onNext = onNext
    self.onPlus = onPlus
    self.onMinus = onMinus
  }

  public var body: some View {
    let fg = Theme.text(model.activity)
    ZStack {
      Theme.background(model.activity)
      VStack(spacing: 2) {
        HStack(spacing: 4) {
          DeltaBand(seconds: model.deltaSeconds)
          Spacer(minLength: 0)
          if let bpm = model.hrBpm { HeartChip(bpm: bpm) }
        }
        HStack(spacing: 4) {
          Text(model.title.uppercased()).font(Theme.label(Theme.Size.label)).lineLimit(1).minimumScaleFactor(0.7)
          if model.kind == .reps {
            Text("LEFT").font(.system(size: 12, weight: .heavy))
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(fg.opacity(0.18), in: Capsule())
          }
          if let badge = model.badge {
            Text(badge.uppercased()).font(.system(size: 12, weight: .heavy))
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(fg.opacity(0.18), in: Capsule())
          }
        }
        .foregroundStyle(fg)
        dominantRow(fg)
        Text(model.secondary)
          .font(Theme.number(Theme.Size.secondary)).condensed()
          .foregroundStyle(fg.opacity(0.78))
          .lineLimit(1).minimumScaleFactor(0.6)
          .accessibilityLabel(model.secondaryLabel)
        Spacer(minLength: 0)
        if model.kind != .reps {
          Text(model.next).font(.system(size: Theme.Size.small, weight: .semibold)).foregroundStyle(fg.opacity(0.85)).lineLimit(1)
        }
        HStack(spacing: 6) {
          NextButton(activity: model.activity, isLast: model.isLast, action: onNext)
          if let onMissed {
            Button(action: onMissed) {
              Text("NOT\nHEARD").font(.system(size: 12, weight: .heavy)).multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .frame(width: 56, height: 56)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Didn't hear the last cue")
          }
        }
      }
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.top, 2)
      .padding(.bottom, 2)
      if let toast = model.toast {
        Toast(text: toast).padding(.horizontal, 12).padding(.bottom, 66).frame(maxHeight: .infinity, alignment: .bottom)
      }
      if let alarm = model.alarm {
        AlarmBanner(text: alarm, action: "Keep and send", onAction: onAlarm).padding(.horizontal, 6).frame(maxHeight: .infinity, alignment: .top)
      }
    }
  }

  @ViewBuilder
  private func dominantRow(_ fg: Color) -> some View {
    let number = Text(model.dominant)
      .font(Theme.number(Theme.Size.dominant)).condensed()
      .foregroundStyle(fg)
      .lineLimit(1).minimumScaleFactor(0.5)
      .accessibilityLabel(model.dominantLabel)
    if model.kind == .reps {
      HStack(spacing: 0) {
        StepperButton(symbol: "\u{2212}", label: "One fewer rep", pulse: model.approximate, action: onMinus)
        number.frame(maxWidth: .infinity)
        StepperButton(symbol: "+", label: "One more rep", pulse: model.approximate, action: onPlus)
      }
    } else {
      number.frame(maxWidth: .infinity)
    }
  }
}

public struct CoachReadyScreen: View {
  let model: ReadyScreenModel
  var onStart: () -> Void = {}
  var onRecorderOnly: () -> Void = {}

  public init(model: ReadyScreenModel, onStart: @escaping () -> Void = {}, onRecorderOnly: @escaping () -> Void = {}) {
    self.model = model
    self.onStart = onStart
    self.onRecorderOnly = onRecorderOnly
  }

  public var body: some View {
    ZStack {
      Theme.ink
      VStack(spacing: 6) {
        switch model {
        case .loading:
          Spacer()
          Spinner(color: Theme.bone)
          Text("Waiting for the plan from your iPhone").font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
          Spacer()
        case .noPlan:
          Spacer()
          Text("Open the app on your iPhone to build today's session").font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
          Spacer()
          secondaryButton("Recorder only")
        case .ready(let info):
          let tight = !info.chips.isEmpty || info.batteryLine != nil
          HStack(spacing: 6) {
            Text(info.athleteChip).font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.ink)
              .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.bone, in: Capsule())
            Text(info.sessionName.uppercased()).font(Theme.label(Theme.Size.label)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
          }
          Text(info.targetText).font(Theme.number(tight ? Theme.Size.floor + 4 : Theme.Size.dominant)).condensed().lineLimit(1).minimumScaleFactor(0.5)
            .accessibilityLabel("Target \(info.targetText)")
          ForEach(info.chips, id: \.self) { chip in
            Text(chip).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 8).padding(.vertical, 1)
              .background(Theme.bone.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
          }
          if let b = info.batteryLine {
            Text(b).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber).multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Button(action: onStart) {
            Text("START").font(.system(size: 22, weight: .heavy)).foregroundStyle(Theme.ink)
              .frame(maxWidth: .infinity, minHeight: tight ? 48 : 56)
              .background(Theme.finishFlood, in: RoundedRectangle(cornerRadius: 14))
          }.buttonStyle(.plain)
        }
      }
      .foregroundStyle(Theme.bone)
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.vertical, 4)
    }
  }

  private func secondaryButton(_ title: String) -> some View {
    Button(action: onRecorderOnly) {
      Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Theme.bone.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain)
  }
}

/// The finish moment: a flood of colour, the total, one line. Reduce Motion fades instead of animating.
public struct CoachFinishScreen: View {
  let model: FinishScreenModel
  var onDone: () -> Void = {}

  public init(model: FinishScreenModel, onDone: @escaping () -> Void = {}) {
    self.model = model
    self.onDone = onDone
  }

  public var body: some View {
    ZStack {
      (model.early ? Theme.earlyFlood : Theme.finishFlood)
      VStack(spacing: 4) {
        switch model.mode {
        case .saving:
          Spacer()
          Spinner(color: Theme.ink)
          Text("Saving\u{2026}").font(Theme.label(Theme.Size.label))
          Spacer()
        case .saved, .saveFailed:
          Spacer(minLength: 0)
          Text(model.totalText)
            .font(Theme.number(Theme.Size.dominant)).condensed()
            .lineLimit(1).minimumScaleFactor(0.55)
            .accessibilityLabel("Total time \(model.totalText)")
          Text(model.line)
            .font(.system(size: 20, weight: .heavy)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
          if case .saveFailed(let missing) = model.mode {
            Text("Saved what we could. \(missing) station\(missing == 1 ? "" : "s") missing.")
              .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
          } else if let best = model.best, let worst = model.worst {
            Text("Best \(best)").font(.system(size: 15, weight: .semibold))
            Text("Worst \(worst)").font(.system(size: 15, weight: .semibold))
          }
          Spacer(minLength: 0)
          Button(action: onDone) {
            Text("DONE").font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.bone)
              .frame(maxWidth: .infinity, minHeight: 48)
              .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
          }.buttonStyle(.plain)
        }
      }
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.vertical, 4)
    }
  }
}

/// The long-press menu: Undo, End. Shown over the session.
public struct CoachMenuScreen: View {
  var onUndo: () -> Void = {}
  var onEnd: () -> Void = {}
  var onCancel: () -> Void = {}

  public init(onUndo: @escaping () -> Void = {}, onEnd: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
    self.onUndo = onUndo
    self.onEnd = onEnd
    self.onCancel = onCancel
  }

  public var body: some View {
    ZStack {
      Theme.ink
      VStack(spacing: 8) {
        row("Undo last step", fill: Theme.bone, text: Theme.ink, action: onUndo)
        row("End session", fill: Theme.amber, text: Theme.ink, action: onEnd)
        row("Keep going", fill: Theme.bone.opacity(0.16), text: Theme.bone, action: onCancel)
      }
      .padding(.horizontal, Theme.Space.watchEdge)
    }
  }

  private func row(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 20, weight: .heavy)).foregroundStyle(text)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
  }
}
