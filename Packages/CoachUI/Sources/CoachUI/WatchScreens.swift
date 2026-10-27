import CoachKit
import SwiftUI
#if os(watchOS)
import WatchKit
#endif

/// Slim band across the top for the session delta, in words: "PLAN 0:32 DOWN", "LAST 0:12 UP" or "LEVEL". The tag says what the
/// delta is measured against; bone when level or ahead, amber when behind. Never red.
/// Deliberately small (24 pt numbers in a 28 pt band) so the step's own number stays the loudest thing.
struct DeltaBand: View {
  let seconds: Int
  var reference: DeltaReference = .plan
  var height: CGFloat = 26
  /// Wrist down: the display refreshes once a minute, so the delta drops its seconds ("1 MIN DOWN").
  var dimmed = false
  var numberSize: CGFloat = Theme.Size.band

  var bandText: String { dimmed ? DeltaBandWords.bandDimmed(seconds) : DeltaBandWords.band(seconds) }

  var body: some View {
    HStack(spacing: 6) {
      Text(reference.tag).font(.system(size: 11, weight: .heavy)).tracking(0.5).foregroundStyle(Theme.bone.opacity(0.7))
        .lineLimit(1).fixedSize()
      Text(bandText)
        .font(Theme.number(numberSize)).condensed()
        .foregroundStyle(seconds > 0 && !DeltaBandWords.isLevel(seconds) ? Theme.amber : Theme.bone)
        .lineLimit(1).minimumScaleFactor(0.6)
    }
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .background(Theme.ink.opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(DeltaBandWords.accessibility(seconds, reference: reference))
  }
}

/// Test hook: when set, the dominant number is drawn in this colour, so a test can find its ink in a render.
struct DominantProbeKey: EnvironmentKey {
  static let defaultValue: Color? = nil
}

extension EnvironmentValues {
  var dominantProbe: Color? {
    get { self[DominantProbeKey.self] }
    set { self[DominantProbeKey.self] = newValue }
  }
}

/// 41 mm and smaller: the step screen drops to tighter heights so nothing clips under the clock inset.
struct WatchCompactKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var watchCompact: Bool {
    get { self[WatchCompactKey.self] }
    set { self[WatchCompactKey.self] = newValue }
  }
}

/// Screens at or under this height (41 mm is 215 pt) use the compact layout.
let watchCompactMaxHeight: CGFloat = 230

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

/// Shown instead of the number when no heart-rate samples arrive. Amber: a notice, not an alarm.
struct HeartOffChip: View {
  var body: some View {
    Text("HR OFF")
      .font(.system(size: 13, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Theme.amber, in: Capsule())
      .accessibilityLabel("Heart rate off")
  }
}

/// Plain arc spinner: `ProgressView` is a UIKit view that ImageRenderer cannot draw.
struct Spinner: View {
  var color: Color
  @State private var turning = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isLuminanceReduced) private var luminanceReduced
  @Environment(\.watchDimmed) private var forcedDim

  var body: some View {
    Circle().trim(from: 0, to: 0.7)
      .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
      .frame(width: 28, height: 28)
      .rotationEffect(.degrees(turning ? 360 : 0))
      .onAppear {
        guard !reduceMotion, !luminanceReduced, !forcedDim else { return }
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
      }
      .accessibilityLabel("Loading")
  }
}

struct Toast: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Theme.bone)
      .multilineTextAlignment(.center)
      .lineLimit(2).minimumScaleFactor(0.6)
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The alarm as its own screen with one way out, so it never sits over the numbers.
struct AlarmScreen: View {
  let text: String
  let onAction: () -> Void

  var body: some View {
    VStack(spacing: 4) {
      Spacer(minLength: 0)
      Text("RECORDING AT RISK").font(.system(size: 15, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
      Text(text).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
      Spacer(minLength: 0)
      Button(action: onAction) {
        Text("OK").font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.red)
          .frame(maxWidth: .infinity, minHeight: 44)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
      }.buttonStyle(.plain)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, Theme.Space.watchEdge)
    .padding(.top, 2)
    .padding(.bottom, 4)
    .background(Color.red.ignoresSafeArea())
    .accessibilityElement(children: .contain)
  }
}

/// NEXT is an ink button with the station colour as its label. On the last step it becomes a hold-to-finish
/// button and carries no hand-gesture shortcut: an accidental finish cannot be taken back once the workout ends.
struct NextButton: View {
  let activity: Activity
  let isLast: Bool
  var height: CGFloat = 56
  /// Wrist down: the ink button vanishes on the ink background, so it gets a station-colour outline.
  var outlined = false
  let action: () -> Void
  @State private var pressing = false

  var body: some View {
    let label = Text(isLast ? "HOLD TO FINISH" : "NEXT")
      .font(.system(size: isLast ? (height < 44 ? 15 : 17) : 22, weight: .heavy))
      .lineLimit(2).minimumScaleFactor(0.8)
      .foregroundStyle(Theme.background(activity))
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.background(activity), lineWidth: outlined ? 2 : 0))
    if isLast {
      label
        .opacity(pressing ? 0.55 : 1)
        .onLongPressGesture(minimumDuration: 1.0, maximumDistance: 40, perform: action, onPressingChanged: { pressing = $0 })
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Finish session")
        .accessibilityAction { action() }
    } else {
      let button = Button(action: action) { label }
        .buttonStyle(.plain)
        .accessibilityLabel("Next")
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
}

struct StepperButton: View {
  let symbol: String
  let label: String
  let pulse: Bool
  var size: CGFloat = 44
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(symbol)
        .font(.system(size: 30, weight: .heavy))
        .foregroundStyle(Theme.bone)
        .frame(width: size, height: size)
        .background(Theme.ink.opacity(0.88), in: Circle())
        .overlay(Circle().stroke(Theme.bone, lineWidth: pulse ? 3 : 0))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// Wall-ball rest control: a rep that did not count goes back onto reps left. Outlined, not filled, so it never reads
/// as NOT HEARD (amber) or NEXT (ink). At least 44 pt tall.
struct NoRepButton: View {
  static let height: CGFloat = 44
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(count > 0 ? "NO REP \u{00D7}\(count)" : "NO REP")
        .font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.bone)
        .lineLimit(1).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(Theme.ink.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.bone, lineWidth: 3))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(count > 0 ? "No rep. \(count) noted. Tap to add another" : "No rep. Adds one rep back")
  }
}

/// The set line in the rest row, small enough to sit beside NO REP: "SET 4" over "15 reps".
struct RestSetBlock: View {
  let text: String
  let label: String

  var body: some View {
    let parts = text.components(separatedBy: " \u{00B7} ")
    VStack(spacing: 0) {
      Text(parts[0].uppercased()).font(.system(size: 17, weight: .heavy))
      if parts.count > 1 { Text("\(parts[1]) reps").font(.system(size: 13, weight: .bold)).opacity(0.8) }
    }
    .lineLimit(1).minimumScaleFactor(0.7)
    .frame(width: 58, height: NoRepButton.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }
}

/// Shown for a few seconds after a NO REP tap, in the set block's place: takes the last tap back.
struct NoRepUndoChip: View {
  let count: Int
  var height: CGFloat = NoRepButton.height
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 0) {
        Text("UNDO").font(.system(size: 15, weight: .heavy))
        Text("\(count) noted").font(.system(size: 12, weight: .bold))
      }
      .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
      .frame(width: 58, height: height)
      .background(Theme.bone, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Undo the last no rep")
  }
}

/// The compact layout: the snapshot environment says so, or on a real watch the screen is 41 mm or smaller.
func resolveWatchCompact(_ fromEnvironment: Bool) -> Bool {
  #if os(watchOS)
  return fromEnvironment || WKInterfaceDevice.current().screenBounds.height <= watchCompactMaxHeight
  #else
  return fromEnvironment
  #endif
}

/// Splits a row 65 / 35 so NEXT keeps the room and NOT HEARD (a test control, not an athlete control) stays small.
struct SplitRow: Layout {
  var leadingShare: CGFloat = 0.65
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: proposal.width ?? 150, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else {
      subviews.forEach { $0.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height)) }
      return
    }
    let available = bounds.width - spacing
    let lead = (available * leadingShare).rounded()
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: lead, height: bounds.height))
    subviews[1].place(at: CGPoint(x: bounds.minX + lead + spacing, y: bounds.minY),
                      proposal: ProposedViewSize(width: available - lead, height: bounds.height))
  }
}

/// The edge progress ladder: one tick per plan step down the right edge, in station colours. Done ticks are filled,
/// the current one is outlined and wider, the rest are faint. Off until the coach fills `StepScreenModel.ladder`.
struct EdgeLadder: View {
  let ticks: [LadderTick]
  let outline: Color

  var body: some View {
    let tall: CGFloat = ticks.count > 12 ? 6 : 9
    VStack(spacing: 2) {
      ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(tick.state == .done ? Theme.background(tick.activity) : (tick.state == .upcoming ? outline.opacity(0.22) : Color.clear))
          .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(outline.opacity(tick.state == .upcoming ? 0 : 0.7), lineWidth: tick.state == .current ? 2 : 1))
          .frame(width: tick.state == .current ? 7 : 5, height: tall)
      }
    }
    .padding(.trailing, 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(ticks.filter { $0.state == .done }.count) of \(ticks.count) steps done")
  }
}

/// "3:12" becomes 3 and "min" when the wrist is down: the display refreshes once a minute, so seconds would lie.
enum DimClock {
  static func parts(_ clock: String) -> (value: String, unit: String?) {
    let c = clock.split(separator: ":").map(String.init)
    if c.count == 2 { return (c[0], "min") }
    if c.count == 3 { return ("\(c[0]):\(c[1])", nil) }
    return (clock, nil)
  }
}

/// Run, time-based station and rep station: one dominant number each. Max three items besides the delta.
public struct CoachStepScreen: View {
  let model: StepScreenModel
  var onNext: () -> Void = {}
  var onPlus: () -> Void = {}
  var onMinus: () -> Void = {}
  var onNoRep: () -> Void = {}
  var onNoRepUndo: () -> Void = {}
  /// M1's "didn't hear" control, pinned beside NEXT on every coach screen. Nil hides it.
  var onMissed: (() -> Void)?
  var onAlarm: () -> Void = {}

  public init(model: StepScreenModel, onNext: @escaping () -> Void = {}, onPlus: @escaping () -> Void = {}, onMinus: @escaping () -> Void = {}, onNoRep: @escaping () -> Void = {}, onNoRepUndo: @escaping () -> Void = {}, onMissed: (() -> Void)? = nil, onAlarm: @escaping () -> Void = {}) {
    self.onNoRep = onNoRep
    self.onNoRepUndo = onNoRepUndo
    self.onMissed = onMissed
    self.onAlarm = onAlarm
    self.model = model
    self.onNext = onNext
    self.onPlus = onPlus
    self.onMinus = onMinus
  }

  @Environment(\.watchCompact) private var envCompact
  @Environment(\.isLuminanceReduced) private var luminanceReduced
  @Environment(\.watchDimmed) private var forcedDim

  /// Wrist down (Always-On): station colour on ink, minutes only, nothing animated.
  private var dimmed: Bool { luminanceReduced || forcedDim }

  private var compact: Bool { resolveWatchCompact(envCompact) }

  public var body: some View {
    if let alarm = model.alarm {
      AlarmScreen(text: alarm, onAction: onAlarm)
    } else {
      stepBody
    }
  }

  @ViewBuilder
  private var stepBody: some View {
    let fg = dimmed ? Theme.background(model.activity) : Theme.text(model.activity)
    // Wrist down, the station colour is only safe for the big numbers: small text goes bone to stay readable on ink.
    let small = dimmed ? Theme.bone.opacity(0.85) : fg
    let c = compact
    // The Next line is regular-layout only: the compact step screen has no spare row.
    let showNext = !c && model.kind != .reps && !model.next.isEmpty && !model.noRepVisible && !model.noRepUndo
    // The NO REP rest row is a fourth row on a compact screen; every other row gives up a few points for it (40 mm had 16 too many).
    let tight = c && model.noRepVisible
    let button: CGFloat = c ? (tight ? 40 : 44) : 48
    VStack(spacing: tight ? 1 : 2) {
      if let toast = model.toast {
        // A notice takes the band and title rows for its few seconds, so it never covers the dominant number.
        let rowH: CGFloat = tight ? 20 : (c ? 22 : 24)
        Toast(text: toast).frame(maxWidth: .infinity).frame(height: rowH + (tight ? 16 : (c ? 18 : 20)) + (tight ? 1 : 2))
      } else {
        DeltaBand(seconds: model.deltaSeconds, reference: model.reference, height: tight ? 20 : (c ? 22 : 24), dimmed: dimmed,
                  numberSize: c ? 20 : Theme.Size.band)
      }
      if model.toast == nil {
      HStack(spacing: 4) {
        // The title scales down (never "WALL BA\u{2026}"); the LEFT badge and heart chip keep their full width.
        // Compact: the phase word ("Transition", "Changeover") takes the title slot at the title's size, never under 12 pt.
        if c, let badge = model.badge {
          Text(badge.uppercased()).font(Theme.label(15)).lineLimit(1).minimumScaleFactor(0.8)
        } else {
          Text(model.title.uppercased()).font(Theme.label(c ? 15 : Theme.Size.label)).lineLimit(1).minimumScaleFactor(0.4)
          // Regular layout: the phase word sits beside the title (the band's tag slot now names the reference).
          if let badge = model.badge {
            Text(badge.uppercased()).font(.system(size: 11, weight: .heavy)).lineLimit(1).fixedSize()
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(fg.opacity(0.18), in: Capsule())
          }
        }
        if model.kind == .reps {
          // A low-confidence count is flagged in this badge ("LEFT ~"), not inside the number: the digits keep their room.
          Text(model.approximate ? (c ? "LEFT~" : "LEFT ~") : "LEFT").font(.system(size: c ? 10 : 12, weight: .heavy)).lineLimit(1).fixedSize()
            .padding(.horizontal, c ? 4 : 5).padding(.vertical, 1)
            .background(fg.opacity(0.18), in: Capsule())
            .accessibilityLabel(model.approximate ? "Reps left, estimated" : "Reps left")
        }
        Spacer(minLength: 0)
        if model.hrOff {
          HeartOffChip().fixedSize().layoutPriority(2)
        } else if let bpm = model.hrBpm {
          HeartChip(bpm: bpm).fixedSize().layoutPriority(2)
        }
      }
      .foregroundStyle(small)
      .frame(height: tight ? 16 : (c ? 18 : 20))
      }
      dominantRow(fg, compact: c)
      if model.noRepVisible {
        HStack(spacing: 6) {
          if model.noRepUndo {
            NoRepUndoChip(count: model.noRepCount, action: onNoRepUndo)
          } else {
            RestSetBlock(text: model.secondary, label: model.secondaryLabel)
          }
          NoRepButton(count: model.noRepCount, action: onNoRep)
        }
        .padding(.bottom, c ? 1 : 7) // 10 pt in all above NOT HEARD and NEXT (6 pt on 41 mm)
      } else if model.noRepUndo {
        // Throwing has resumed but the chip keeps its 4 s: a mis-tap can still be taken back.
        NoRepUndoChip(count: model.noRepCount, height: c ? 30 : 36, action: onNoRepUndo)
          .frame(maxWidth: .infinity).frame(height: c ? 30 : 36)
      } else {
        Text(model.secondary)
          .font(Theme.number(Theme.Size.secondary)).condensed()
          .foregroundStyle(fg.opacity(0.78))
          .lineLimit(1).minimumScaleFactor(0.6)
          .frame(height: c ? 30 : 34)
          .accessibilityLabel(model.secondaryLabel)
      }
      if showNext {
        Text(model.next)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(dimmed ? small : fg.opacity(0.85))
          .lineLimit(1).minimumScaleFactor(0.7)
          .frame(height: 20)
      }
      Spacer(minLength: 0)
      if let onMissed {
        SplitRow {
          NextButton(activity: model.activity, isLast: model.isLast, height: button, outlined: dimmed, action: onNext)
          Button(action: onMissed) {
            Text("NOT\nHEARD").font(.system(size: c ? 12 : 13, weight: .semibold)).multilineTextAlignment(.center)
              .lineLimit(2).minimumScaleFactor(0.8)
              .foregroundStyle(Theme.ink)
              .frame(maxWidth: .infinity)
              .frame(height: button)
              .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Didn't hear the last cue")
        }
      } else {
        NextButton(activity: model.activity, isLast: model.isLast, height: button, outlined: dimmed, action: onNext)
      }
    }
    .padding(.leading, Theme.Space.watchEdge)
    // With the ladder on, the right edge keeps clear of it (4 pt more than the ladder's own width).
    .padding(.trailing, Theme.Space.watchEdge + ((model.ladder?.isEmpty ?? true) ? 0 : 4))
    .padding(.top, c ? 1 : 2)
    .padding(.bottom, c ? 3 : 4)
    .background((dimmed ? Theme.ink : Theme.background(model.activity)).ignoresSafeArea())
    .overlay(alignment: .trailing) {
      // Compact: start below the title row, so the ticks never run alongside the heart-rate chip.
      if let ladder = model.ladder, !ladder.isEmpty { EdgeLadder(ticks: ladder, outline: fg).padding(.top, c ? 44 : 0) }
    }
    .transaction { if dimmed { $0.animation = nil } }
  }

  @Environment(\.dominantProbe) private var probe

  @ViewBuilder
  private func dominantRow(_ fg: Color, compact c: Bool) -> some View {
    let height: CGFloat = c ? (model.noRepVisible ? 40 : 44) : (model.noRepVisible ? 48 : 52)
    let clock: (value: String, unit: String?) = dimmed && model.kind != .reps ? DimClock.parts(model.dominant) : (value: model.dominant, unit: nil)
    // 0.9 keeps the digits at 40 pt of ink or more; a wider time such as 10:41 on 40 mm shrinks this far, never to "10:\u{2026}".
    let digits = Text(clock.value)
      .font(Theme.number(Theme.Size.dominant)).condensed()
      .foregroundStyle(probe ?? fg)
      .lineLimit(1).minimumScaleFactor(0.9)
    let number = HStack(alignment: .firstTextBaseline, spacing: 4) {
      digits
      if let unit = clock.unit { Text(unit).font(Theme.label(24)).foregroundStyle(fg.opacity(0.78)) }
    }
      .frame(height: height)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.dominantLabel)
    if model.kind == .reps {
      HStack(spacing: 0) {
        StepperButton(symbol: "\u{2212}", label: "One fewer rep", pulse: model.approximate, size: c ? 40 : 44, action: onMinus)
        number.frame(maxWidth: .infinity)
        StepperButton(symbol: "+", label: "One more rep", pulse: model.approximate, size: c ? 40 : 44, action: onPlus)
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
      Theme.ink.ignoresSafeArea()
      VStack(spacing: 4) {
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
            if let chip = info.athleteChip {
              Text(chip).font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.bone, in: Capsule())
            }
            Text(info.sessionName.uppercased()).font(Theme.label(Theme.Size.label)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
          }
          Text(info.targetText).font(Theme.number(tight ? Theme.Size.floor : Theme.Size.dominant)).condensed().lineLimit(1).minimumScaleFactor(0.5)
            .accessibilityLabel("Target \(info.targetText)")
          if let line = Self.warningLine(info) {
            Text(line.short).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
              .foregroundStyle(info.batteryLine != nil ? Theme.amber : Theme.bone)
              .lineLimit(2).minimumScaleFactor(0.8)
              .padding(.horizontal, 8).padding(.vertical, 1)
              .background(Theme.bone.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
              .accessibilityLabel(line.full)
          }
          if let line = info.line, Self.warningLine(info) == nil {
            Text(line).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.bone.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.7)
          }
          Spacer(minLength: 0)
          Button(action: onStart) {
            Text("START").font(.system(size: 22, weight: .heavy)).foregroundStyle(Theme.ink)
              .frame(maxWidth: .infinity, minHeight: tight ? 40 : 56)
              .background(Theme.finishFlood, in: RoundedRectangle(cornerRadius: 14))
          }.buttonStyle(.plain)
        }
      }
      .foregroundStyle(Theme.bone)
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.top, 4)
      .padding(.bottom, 10)
    }
  }

  /// All warnings as one short line ("No headphones · Heart rate off · Battery 54%"), so START stays on screen.
  /// The full sentences stay in the accessibility label.
  static func warningLine(_ info: ReadyInfo) -> (short: String, full: String)? {
    let all = info.chips + (info.batteryLine.map { [$0] } ?? [])
    guard !all.isEmpty else { return nil }
    func head(_ t: String) -> String {
      if let i = t.firstIndex(of: ":") { return String(t[..<i]) }
      if let r = t.range(of: ". ") { return String(t[..<r.lowerBound]) }
      return t
    }
    return (all.map(head).joined(separator: " \u{00B7} "), all.joined(separator: ". "))
  }

  private func secondaryButton(_ title: String) -> some View {
    Button(action: onRecorderOnly) {
      Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Theme.bone.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain)
  }
}

/// The total as a clock that counts up; `value` is animated by SwiftUI, so the digits run from 0:00 to the total.
struct CountUpClock: View, Animatable {
  var value: Double

  var animatableData: Double {
    get { value }
    set { value = newValue }
  }

  var body: some View {
    Text(Fmt.clock(Int(value))).monospacedDigit()
  }
}

/// The completed stations in their own colours, filling in from the left. Not-done stations stay dim.
struct FinishStrip: View {
  let stations: [FinishStation]
  let fill: CGFloat

  var body: some View {
    ProportionalStrip(items: stations.map { ($0.done ? Theme.background($0.activity) : Theme.bone.opacity(0.18), Double(max($0.seconds, 1))) },
                      height: 16, gap: 2)
      .mask {
        GeometryReader { g in
          Rectangle().frame(width: g.size.width * fill, height: g.size.height)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(4)
      .background(Theme.ink, in: Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(stations.filter(\.done).count) of \(stations.count) stations done")
  }
}

/// The finish moment: a flood of colour, the total counting up to its value, the stations filling in, one line,
/// shown at once while the files close behind it. For a few seconds after a normal finish, UNDO reopens the
/// last step. Reduce Motion: the total and the strip fade in instead. `animate: false` shows the end state.
public struct CoachFinishScreen: View {
  let model: FinishScreenModel
  let animate: Bool
  var onDone: () -> Void = {}
  var onUndo: () -> Void = {}
  @State private var shown: Double
  @State private var fill: CGFloat
  @State private var fade: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.watchCompact) private var envCompact
  private var compact: Bool { resolveWatchCompact(envCompact) }
  private var isSaveFailure: Bool {
    if case .saveFailed = model.mode { return true }
    return false
  }

  public init(model: FinishScreenModel, animate: Bool = true, onDone: @escaping () -> Void = {}, onUndo: @escaping () -> Void = {}) {
    self.model = model
    self.animate = animate
    self.onDone = onDone
    self.onUndo = onUndo
    _shown = State(initialValue: animate ? 0 : Double(model.totalSeconds))
    _fill = State(initialValue: animate ? 0 : 1)
    _fade = State(initialValue: animate ? 0 : 1)
  }

  public var body: some View {
    ZStack {
      (model.early ? Theme.finishMomentEarly : Theme.finishMoment).ignoresSafeArea()
      VStack(spacing: compact ? 2 : 3) {
        Spacer(minLength: 0)
        total
          .font(Theme.number(compact ? 44 : 52)).condensed()
          .lineLimit(1).minimumScaleFactor(0.55)
          .opacity(reduceMotion ? fade : 1)
          .accessibilityLabel("Total time \(model.totalText)")
        if !model.stations.isEmpty, !(compact && isSaveFailure) {
          FinishStrip(stations: model.stations, fill: reduceMotion ? 1 : fill).opacity(reduceMotion ? fade : 1)
        }
        Text(model.line)
          .font(.system(size: compact ? 16 : 20, weight: .heavy)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
        if case .saveFailed(let missing) = model.mode {
          Text("Saved what we could. \(missing) station\(missing == 1 ? "" : "s") missing.")
            .font(.system(size: compact ? 13 : 14, weight: .semibold)).multilineTextAlignment(.center)
        } else if !compact, model.undoSecondsLeft == nil, let best = model.best, let worst = model.worst {
          Text("Best \(best)").font(.system(size: 14, weight: .semibold))
          Text("Worst \(worst)").font(.system(size: 14, weight: .semibold))
        }
        Spacer(minLength: 0)
        if let left = model.undoSecondsLeft {
          Button(action: onUndo) {
            Text("UNDO \(left)").font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.ink)
              .frame(maxWidth: .infinity, minHeight: 40)
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.ink, lineWidth: 3))
          }.buttonStyle(.plain)
        } else if model.saving {
          Text("Saving\u{2026}").font(.system(size: 15, weight: .semibold))
        }
        if model.undoSecondsLeft == nil, !model.saving {
          Button(action: onDone) {
            Text("DONE").font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.bone)
              .frame(maxWidth: .infinity, minHeight: compact ? 40 : 44)
              .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
          }.buttonStyle(.plain)
        }
      }
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.top, 2)
      .padding(.bottom, 4)
    }
    .onAppear {
      guard animate else { return }
      if reduceMotion {
        shown = Double(model.totalSeconds)
        withAnimation(.easeIn(duration: 0.4)) { fade = 1 }
      } else {
        withAnimation(.easeOut(duration: 1.5)) { shown = Double(model.totalSeconds) }
        withAnimation(.easeOut(duration: 1.2).delay(0.3)) { fill = 1 }
        fade = 1
      }
    }
  }

  @ViewBuilder
  private var total: some View {
    if animate, !reduceMotion, model.totalSeconds > 0 {
      CountUpClock(value: shown)
    } else {
      Text(model.totalText)
    }
  }
}

/// The long-press menu: Undo, End (and Skip station on a station). Shown over the session. With the Skip row there are four
/// rows: they scroll (Digital Crown, swipe), 44 pt each on a compact watch, and the first three show without scrolling.
public struct CoachMenuScreen: View {
  var canSkip = false
  var onUndo: () -> Void = {}
  var onSkip: () -> Void = {}
  var onEnd: () -> Void = {}
  var onCancel: () -> Void = {}
  @Environment(\.watchCompact) private var envCompact

  public init(canSkip: Bool = false, onUndo: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}, onEnd: @escaping () -> Void = {},
              onCancel: @escaping () -> Void = {}) {
    self.canSkip = canSkip
    self.onUndo = onUndo
    self.onSkip = onSkip
    self.onEnd = onEnd
    self.onCancel = onCancel
  }

  public var body: some View {
    ZStack {
      Theme.ink.ignoresSafeArea()
      if canSkip {
        let height: CGFloat = resolveWatchCompact(envCompact) ? 44 : 52
        ScrollView {
          VStack(spacing: 6) {
            row("Undo last step", fill: Theme.bone, text: Theme.ink, height: height, action: onUndo)
            row("Skip station", fill: Theme.bone.opacity(0.16), text: Theme.bone, height: height, action: onSkip)
            row("End session", fill: Theme.amber, text: Theme.ink, height: height, action: onEnd)
            row("Keep going", fill: Theme.bone.opacity(0.16), text: Theme.bone, height: height, action: onCancel)
          }
          .padding(.horizontal, Theme.Space.watchEdge)
        }
      } else {
        VStack(spacing: 8) {
          row("Undo last step", fill: Theme.bone, text: Theme.ink, action: onUndo)
          row("End session", fill: Theme.amber, text: Theme.ink, action: onEnd)
          row("Keep going", fill: Theme.bone.opacity(0.16), text: Theme.bone, action: onCancel)
        }
        .padding(.horizontal, Theme.Space.watchEdge)
      }
    }
  }

  private func row(_ title: String, fill: Color, text: Color, height: CGFloat = 52, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 20, weight: .heavy)).foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
  }
}

/// "Skip Row?" with Do it later (training only), Skip it, Back. Three deliberate taps guard a skip: hold, the menu row, this.
public struct CoachSkipConfirmScreen: View {
  let title: String
  let activity: Activity
  let canLater: Bool
  var onLater: () -> Void = {}
  var onSkip: () -> Void = {}
  var onBack: () -> Void = {}
  @Environment(\.watchCompact) private var envCompact

  public init(title: String, activity: Activity, canLater: Bool, onLater: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {},
              onBack: @escaping () -> Void = {}) {
    self.title = title
    self.activity = activity
    self.canLater = canLater
    self.onLater = onLater
    self.onSkip = onSkip
    self.onBack = onBack
  }

  public var body: some View {
    let height: CGFloat = resolveWatchCompact(envCompact) ? 44 : 52
    ZStack {
      Theme.ink.ignoresSafeArea()
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          Circle().fill(Theme.background(activity)).frame(width: 12, height: 12)
          Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, alignment: .leading)
        if canLater { button("Do it later", fill: Theme.bone, text: Theme.ink, height: height, action: onLater) }
        button("Skip it", fill: Theme.amber, text: Theme.ink, height: height, action: onSkip)
        button("Back", fill: Theme.bone.opacity(0.16), text: Theme.bone, height: height, action: onBack)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.top, 2)
    }
  }

  private func button(_ title: String, fill: Color, text: Color, height: CGFloat, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 18, weight: .heavy)).foregroundStyle(text)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
  }
}

/// After the last step: a station that was moved to later is still undone. Do it now, or finish without it.
public struct CoachLeftoverScreen: View {
  let title: String
  let activity: Activity
  var onNow: () -> Void = {}
  var onWithout: () -> Void = {}
  @Environment(\.watchCompact) private var envCompact

  public init(title: String, activity: Activity, onNow: @escaping () -> Void = {}, onWithout: @escaping () -> Void = {}) {
    self.title = title
    self.activity = activity
    self.onNow = onNow
    self.onWithout = onWithout
  }

  public var body: some View {
    let height: CGFloat = resolveWatchCompact(envCompact) ? 44 : 52
    ZStack {
      Theme.ink.ignoresSafeArea()
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          Circle().fill(Theme.background(activity)).frame(width: 12, height: 12)
          Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Theme.bone)
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        Button(action: onNow) {
          Text("Do it now").font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: height).background(Theme.finishFlood, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
        Button(action: onWithout) {
          Text("Finish without it").font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.bone).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: height).background(Theme.bone.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
      }
      .padding(.horizontal, Theme.Space.watchEdge)
      .padding(.top, 2)
    }
  }
}
