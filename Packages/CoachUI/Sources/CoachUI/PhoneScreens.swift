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

  public init(division: Division = .openMen, targetSeconds: Int = 5400, type: SessionType = .fullSim,
              wallBallReps: Int = PlanBuilder.defaultFocusReps, send: SendState = .idle) {
    self.division = division
    self.targetSeconds = targetSeconds
    self.type = type
    self.wallBallReps = wallBallReps
    self.send = send
  }

  public var plan: SessionPlan { PlanBuilder.build(division: division, target: targetSeconds, type: type, wallBallReps: wallBallReps) }
}

struct Card<Content: View>: View {
  let content: Content
  init(@ViewBuilder _ content: () -> Content) { self.content = content() }

  var body: some View {
    content
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.bone.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
  }
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
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(selected ? Theme.ink : Theme.bone)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(selected ? Theme.bone : Theme.bone.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// First-launch setup: division, target, session, the estimated split, send to watch.
public struct SetupScreen: View {
  let model: SetupModel
  var onDivision: (Division) -> Void = { _ in }
  var onTargetStep: (Int) -> Void = { _ in }
  var onType: (SessionType) -> Void = { _ in }
  var onWallBallReps: (Int) -> Void = { _ in }
  var onSend: () -> Void = {}

  public init(model: SetupModel, onDivision: @escaping (Division) -> Void = { _ in }, onTargetStep: @escaping (Int) -> Void = { _ in },
              onType: @escaping (SessionType) -> Void = { _ in }, onWallBallReps: @escaping (Int) -> Void = { _ in },
              onSend: @escaping () -> Void = {}) {
    self.model = model
    self.onDivision = onDivision
    self.onTargetStep = onTargetStep
    self.onType = onType
    self.onWallBallReps = onWallBallReps
    self.onSend = onSend
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Build today's session").font(Theme.number(30)).condensed()
      Card {
        VStack(alignment: .leading, spacing: 8) {
          label("Division")
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.prefix(2))) { d in Choice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
          HStack(spacing: 8) {
            ForEach(Array(Division.allCases.suffix(2))) { d in Choice(title: d.title, selected: model.division == d) { onDivision(d) } }
          }
        }
      }
      Card {
        VStack(alignment: .leading, spacing: 8) {
          label("Target finish")
          HStack(spacing: 10) {
            stepButton("\u{2212}", "Five minutes less") { onTargetStep(-300) }
            Text(Fmt.clock(model.targetSeconds)).font(Theme.number(44)).condensed().frame(maxWidth: .infinity)
              .accessibilityLabel("Target finish \(Fmt.clock(model.targetSeconds))")
            stepButton("+", "Five minutes more") { onTargetStep(300) }
          }
        }
      }
      Card {
        VStack(alignment: .leading, spacing: 8) {
          label("Session")
          ForEach(SessionType.allCases) { t in
            Choice(title: "\(t.title) \u{00B7} \(t.detail(wallBallReps: model.wallBallReps))", selected: model.type == t) { onType(t) }
          }
          if model.type == .wallBallFocus {
            label("Wall balls per round")
            HStack(spacing: 8) {
              ForEach(PlanBuilder.focusRepOptions, id: \.self) { n in
                Choice(title: "\(n)", selected: model.wallBallReps == n) { onWallBallReps(n) }
              }
            }
          }
        }
      }
      splitSummary
      sendArea
    }
    .foregroundStyle(Theme.bone)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Theme.ink)
  }

  private func label(_ s: String) -> some View {
    Text(s.uppercased()).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.bone.opacity(0.7))
  }

  private func stepButton(_ symbol: String, _ a11y: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(symbol).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
        .frame(width: 52, height: 52).background(Theme.bone, in: Circle())
    }.buttonStyle(.plain).accessibilityLabel(a11y)
  }

  private var splitSummary: some View {
    let plan = model.plan
    let run = plan.steps.first { $0.isRun }?.targetSeconds ?? 0
    return Card {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          label("Plan")
          Text("ESTIMATE").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.amber, in: Capsule())
        }
        Text("\(plan.steps.filter(\.isRun).count) runs at \(Fmt.clock(run)) including transitions").font(.system(size: 17, weight: .semibold))
        ProportionalStrip(items: plan.steps.filter { !$0.isRun }.map { (Theme.background($0.activity), Double($0.targetSeconds)) }, height: 14)
        Text("Total \(Fmt.clock(plan.plannedSeconds)). Default split: runs about half, stations by typical shares.")
          .font(.system(size: 13)).foregroundStyle(Theme.bone.opacity(0.7))
      }
    }
  }

  private var sendArea: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: onSend) {
        HStack(spacing: 8) {
          if case .sending = model.send { Spinner(color: Theme.ink) }
          Text(sendTitle).font(.system(size: 20, weight: .heavy))
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Theme.finishFlood, in: RoundedRectangle(cornerRadius: 16))
      }.buttonStyle(.plain)
      switch model.send {
      case .idle: EmptyView()
      case .sending(let name): Text("Sending plan to \(name)\u{2026}").font(.system(size: 15))
      case .sent: Text("Plan on your watch").font(.system(size: 15, weight: .semibold))
      case .watchAppMissing:
        Text("Install on your watch: Watch app \u{2192} Available apps").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
      case .failed:
        Text("Watch not reachable. Open the app on your watch, then Send again").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
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

// MARK: Summary

public enum SummaryState: Equatable {
  /// No sessions yet.
  case empty
  case syncing(percent: Int)
  case failed
  case ready(CoachResult)
}

struct FadeChart: View {
  let rows: [CoachResult.Row]

  var body: some View {
    let runs = rows.filter { $0.step.isRun }
    let base = runs.first?.actualSeconds
    let deltas: [Int?] = runs.map { r in
      guard let a = r.actualSeconds, let base else { return nil }
      return a - base
    }
    let maxAbs = max(10, deltas.compactMap { $0 }.map(abs).max() ?? 10)
    return VStack(spacing: 4) {
      HStack(alignment: .center, spacing: 6) {
        ForEach(Array(deltas.enumerated()), id: \.offset) { _, d in
          let h = max(3, CGFloat(abs(d ?? 0)) / CGFloat(maxAbs) * 46)
          VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
              Color.clear
              if let d, d > 0 { RoundedRectangle(cornerRadius: 3).fill(Theme.amber).frame(height: h) }
            }.frame(height: 50)
            Rectangle().fill(Theme.bone.opacity(0.35)).frame(height: 1)
            ZStack(alignment: .top) {
              Color.clear
              if let d {
                if d <= 0 { RoundedRectangle(cornerRadius: 3).fill(Theme.bone).frame(height: h) }
              } else {
                RoundedRectangle(cornerRadius: 3).fill(Theme.bone.opacity(0.2)).frame(height: 3)
              }
            }.frame(height: 50)
          }
          .frame(maxWidth: .infinity)
        }
      }
      HStack(spacing: 6) {
        ForEach(Array(runs.enumerated()), id: \.offset) { i, _ in
          Text("R\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.bone.opacity(0.7)).frame(maxWidth: .infinity)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Run times against run 1")
  }
}

/// Insight, then table, fade chart, wall balls, share, export. Pure layout; the app wraps it in a ScrollView.
public struct SummaryScreen: View {
  let state: SummaryState
  var onShare: () -> Void = {}
  var onExport: () -> Void = {}
  var shareError: Bool = false

  public init(state: SummaryState, shareError: Bool = false, onShare: @escaping () -> Void = {}, onExport: @escaping () -> Void = {}) {
    self.state = state
    self.shareError = shareError
    self.onShare = onShare
    self.onExport = onExport
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch state {
      case .empty:
        Text("Your first session lands here after you finish on the watch").font(.system(size: 20, weight: .semibold))
      case .syncing(let p):
        Text("Syncing from watch\u{2026} keep your phone near it").font(.system(size: 20, weight: .semibold))
        ProportionalStrip(items: [(Theme.finishFlood, Double(max(p, 1))), (Theme.bone.opacity(0.15), Double(max(100 - p, 1)))], height: 10)
        Text("\(p)%").font(Theme.number(36)).condensed()
      case .failed:
        Text("Not received yet. On your watch: Home \u{2192} Send unsent").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.amber)
      case .ready(let r):
        ready(r)
      }
    }
    .foregroundStyle(Theme.bone)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Theme.ink)
  }

  @ViewBuilder
  private func ready(_ r: CoachResult) -> some View {
    let insight = InsightPicker.pick(r)
    let d = r.totalSeconds - r.plan.plannedSeconds
    Text(r.shortTitle.uppercased()).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.bone.opacity(0.7))
    Text(insight.headline).font(Theme.number(30)).condensed().fixedSize(horizontal: false, vertical: true)
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(Fmt.clock(r.totalSeconds)).font(Theme.number(56)).condensed()
      if !r.early {
        Text("\(Fmt.gap(d)) \(d <= 0 ? "under" : "over") plan").font(.system(size: 17, weight: .bold))
          .foregroundStyle(d > 0 ? Theme.amber : Theme.bone)
      }
    }
    Card {
      VStack(spacing: 6) {
        ForEach(r.rows, id: \.step.index) { row in
          HStack {
            Circle().fill(Theme.background(row.step.activity)).frame(width: 10, height: 10)
            Text(row.step.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer()
            if let a = row.actualSeconds, let dl = row.deltaSeconds {
              Text(Fmt.clock(a)).font(.system(size: 15, weight: .bold)).monospacedDigit()
              Text(Fmt.delta(dl)).font(.system(size: 15, weight: .heavy)).monospacedDigit()
                .foregroundStyle(dl > 0 ? Theme.amber : Theme.bone).frame(width: 56, alignment: .trailing)
            } else {
              Text("not done").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.bone.opacity(0.45))
            }
          }
        }
      }
    }
    Card {
      VStack(alignment: .leading, spacing: 8) {
        Text("RUNS AGAINST RUN 1").font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.bone.opacity(0.7))
        FadeChart(rows: r.rows)
      }
    }
    let sets = r.wallBallSets()
    if !sets.isEmpty {
      Card {
        VStack(alignment: .leading, spacing: 6) {
          Text("WALL BALLS").font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.bone.opacity(0.7))
          ForEach(Array(sets.enumerated()), id: \.offset) { i, s in
            HStack {
              Text("Set \(i + 1)").font(.system(size: 15, weight: .semibold))
              Text("\(s.reps) reps").font(.system(size: 15))
              Spacer()
              Text(i == 0 ? "\u{2014}" : "rest \(Fmt.gap(s.restBeforeSeconds))").font(.system(size: 15, weight: .bold)).monospacedDigit()
            }
          }
          Text("Total rest \(Fmt.gap(WallBallAnalysis.totalRestSeconds(sets))). Rep count is a beta estimate.")
            .font(.system(size: 13)).foregroundStyle(Theme.bone.opacity(0.7))
        }
      }
    }
    VStack(spacing: 8) {
      actionButton("Share card", fill: Theme.finishFlood, text: Theme.ink, action: onShare)
      if shareError {
        Text("Couldn't make the card. Try again").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
      }
      actionButton("Export session zip", fill: Theme.bone.opacity(0.14), text: Theme.bone, action: onExport)
    }
  }

  private func actionButton(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 18, weight: .heavy)).foregroundStyle(text)
        .frame(maxWidth: .infinity, minHeight: 52).background(fill, in: RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
  }
}

// MARK: Share card

/// Dark still: the big total, the station strip in station colours. Honest about partial sessions.
public struct ShareCardView: View {
  let result: CoachResult

  public init(result: CoachResult) { self.result = result }

  public var body: some View {
    let d = result.totalSeconds - result.plan.plannedSeconds
    ZStack {
      Theme.ink
      VStack(alignment: .leading, spacing: 10) {
        Text(result.shortTitle.uppercased()).font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.bone.opacity(0.7))
        Spacer(minLength: 0)
        Text(Fmt.clock(result.totalSeconds)).font(.system(size: 120, weight: .heavy)).condensed()
          .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(Theme.bone)
        if !result.early {
          Text("\(Fmt.gap(d)) \(d <= 0 ? "under" : "over") target").font(.system(size: 28, weight: .heavy))
            .foregroundStyle(d > 0 ? Theme.amber : Theme.finishFlood)
        }
        Spacer(minLength: 0)
        stationStrip
        Text(InsightPicker.pick(result).headline).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.bone.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(28)
    }
    .frame(width: 360, height: 450)
  }

  private var stationStrip: some View {
    ProportionalStrip(items: result.rows.filter { !$0.step.isRun }.map { row in
      (row.actualSeconds == nil ? Theme.bone.opacity(0.15) : Theme.background(row.step.activity), Double(row.actualSeconds ?? row.step.targetSeconds))
    }, height: 34)
  }
}
