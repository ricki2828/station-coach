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
    if let moment { return moment.kicker }
    if result.early { return "\(type.title) \u{00B7} \(result.completedStationCount) of \(result.plan.stationCount) stations" }
    return type.title
  }

  private var heroLine: String? {
    if let moment { return moment.line }
    if result.early { return "Ended early" }
    let d = result.totalSeconds - result.plan.plannedSeconds
    return "\(Fmt.gap(d)) \(d <= 0 ? "under" : "over") target"
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Wordmark(size: 18)
      HeroCard(color: color, textColor: textColor) {
        VStack(alignment: .leading, spacing: 4) {
          Text(kicker).font(.system(size: 13, weight: .heavy)).textCase(.uppercase).tracking(1).lineLimit(1).minimumScaleFactor(0.7)
          Text(moment?.hero ?? Fmt.clock(result.totalSeconds)).phoneHero(size: 110).lineLimit(1).minimumScaleFactor(0.4)
          if let heroLine {
            Text(heroLine).font(.system(size: 17, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.top, 16)
      StationStrip(result: result, labelled: true, height: 14).padding(.top, 20)
      Text(InsightPicker.pick(result).headline).font(.system(size: 18, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
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
