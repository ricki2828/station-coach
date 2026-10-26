import CoachKit
import SwiftUI

/// Share card v2: 360 x 450 pt, rendered at scale 3 for 1080 x 1350. Light page, wordmark, a hero card in the
/// session colour, a labelled station strip, the insight, and a date / brand footer. Partial sessions say so
/// in the kicker and drop the target line. A moment swaps the hero card's colour and words.
public struct ShareCardV2: View {
  public static let size = CGSize(width: 360, height: 450)
  public static let renderScale: CGFloat = 3

  let result: CoachResult
  let dateText: String
  let moment: MomentDisplay?

  public init(result: CoachResult, dateText: String? = nil, moment: MomentDisplay? = nil) {
    self.result = result
    self.dateText = dateText ?? Self.date(result.startedAtEpochMs)
    self.moment = moment
  }

  static func date(_ epochMs: Int64) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE d MMM"
    return f.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
  }

  private var type: SessionType { result.plan.type }
  private var color: Color { moment?.flood ?? PhoneTheme.sessionColor(type) }
  private var textColor: Color { moment?.text ?? PhoneTheme.sessionText(type) }

  private var kicker: String {
    if let moment { return result.early && moment.partial == nil ? moment.kicker + " \u{00B7} \(result.completedStationCount) of \(result.plan.stationCount) stations" : moment.kicker }
    if result.early { return "\(type.title) \u{00B7} \(result.completedStationCount) of \(result.plan.stationCount) stations" }
    return type.title
  }

  private var heroLine: String? {
    if result.early { return "Ended early" }
    if let moment { return moment.line }
    let d = result.totalSeconds - result.plan.plannedSeconds
    return "\(Fmt.gap(d)) \(d <= 0 ? "under" : "over") target"
  }

  /// A partial card never compares against the whole plan: it speaks about the stations done, against the plan for those parts.
  private var insight: String {
    guard result.early else { return InsightPicker.pick(result).headline }
    let done = result.rows.filter { $0.actualSeconds != nil }
    let actual = done.reduce(0) { $0 + ($1.actualSeconds ?? 0) }
    let planned = done.reduce(0) { $0 + $1.step.targetSeconds }
    let d = actual - planned
    let n = result.completedStationCount
    if abs(d) < 5 { return "On plan through \(n) stations." }
    return "\(Fmt.gap(d)) \(d < 0 ? "ahead of" : "behind") plan through \(n) stations."
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Wordmark(size: 18)
      HeroCard(color: color, textColor: textColor) {
        VStack(alignment: .leading, spacing: 4) {
          if let badge = moment?.badge {
            Text(badge).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Theme.ink)
              .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.bone, in: Capsule())
          }
          Text(kicker).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1).lineLimit(1).minimumScaleFactor(0.7)
          Text(moment?.hero ?? Fmt.clock(result.totalSeconds)).phoneHero(size: 110).lineLimit(1).minimumScaleFactor(0.4)
          if let heroLine {
            Text(heroLine).font(.system(size: 17, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.top, 16)
      ShareStrip(result: result).padding(.top, 20)
      Text(insight).font(.system(size: 18, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
        .fixedSize(horizontal: false, vertical: true).padding(.top, 18)
      Spacer(minLength: 8)
      HStack {
        Text(dateText).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
        Spacer()
        Text(Brand.name).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1)
      }
      .foregroundStyle(PhoneTheme.muted)
    }
    .padding(20)
    .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    .background(PhoneTheme.paper)
  }
}

/// The card's labelled strip. Same geometry as `StationStrip`, but labels that would touch their neighbour drop to a second row.
struct ShareStrip: View {
  let result: CoachResult
  static let barHeight: CGFloat = 14
  static let minLabelGap: CGFloat = 5

  private var rows: [CoachResult.Row] { result.rows }

  private func shortName(_ a: Activity) -> String {
    switch a {
    case .skierg: return "Ski"
    case .sledPush: return "Push"
    case .sledPull: return "Pull"
    case .burpeeBroadJump: return "BBJ"
    case .row: return "Row"
    case .farmersCarry: return "Carry"
    case .sandbagLunges: return "Lunge"
    case .wallBalls: return "WB"
    default: return "Run"
    }
  }

  /// Conservative width of a 10 pt heavy caps label with +0.5 tracking.
  private func labelWidth(_ s: String) -> CGFloat { CGFloat(s.count) * 7.4 }

  var body: some View {
    let weights = rows.map { Double(max(1, $0.actualSeconds ?? $0.step.targetSeconds)) }
    let total = weights.reduce(0, +)
    VStack(spacing: 5) {
      GeometryReader { geo in
        let avail = geo.size.width - CGFloat(max(0, rows.count - 1)) * 2
        HStack(spacing: 2) {
          ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
            let w = max(2, avail * weights[i] / total)
            if r.actualSeconds != nil {
              RoundedRectangle(cornerRadius: 2).fill(PhoneTheme.stationColor(r.step.activity)).frame(width: w)
            } else {
              RoundedRectangle(cornerRadius: 2).stroke(PhoneTheme.hairline, lineWidth: 1).frame(width: w)
            }
          }
        }
      }
      .frame(height: Self.barHeight)
      GeometryReader { geo in
        let avail = geo.size.width - CGFloat(max(0, rows.count - 1)) * 2
        let placed = labels(avail: avail, total: total, weights: weights, width: geo.size.width)
        ForEach(placed, id: \.index) { p in
          Text(p.name)
            .font(.system(size: 10, weight: .heavy)).textCase(.uppercase).tracking(0.5)
            .foregroundStyle(rows[p.index].actualSeconds != nil ? PhoneTheme.inkText : PhoneTheme.muted)
            .fixedSize()
            .position(x: p.x, y: p.row == 0 ? 7 : 21)
        }
      }
      .frame(height: 28)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Station strip, \(result.completedStationCount) of \(result.plan.stationCount) stations done")
  }

  private struct Placed { let index: Int; let name: String; let x: CGFloat; let row: Int }

  private func labels(avail: CGFloat, total: Double, weights: [Double], width: CGFloat) -> [Placed] {
    var out: [Placed] = []
    var right: [CGFloat] = [-.infinity, -.infinity]  // right edge of the last label on each row
    var start: CGFloat = 0
    for (i, r) in rows.enumerated() {
      let w = avail * weights[i] / total
      defer { start += w + 2 }
      guard !r.step.isRun else { continue }
      let name = shortName(r.step.activity)
      let lw = labelWidth(name)
      let x = min(max(start + w / 2, lw / 2), width - lw / 2)
      let left = x - lw / 2
      let row = left - right[0] >= Self.minLabelGap ? 0 : (left - right[1] >= Self.minLabelGap ? 1 : 1)
      right[row] = x + lw / 2
      out.append(Placed(index: i, name: name, x: x, row: row))
    }
    return out
  }
}
