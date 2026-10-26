import CoachKit
import SwiftUI

/// Home: the run-fade hero, one preset next session, the last session and the race target.
/// Wrap in a ScrollView at the call site; the catalog renders it at full height.
public struct HomeScreen: View {
  let model: HomeModel
  let today: Date
  let onStart: (SessionType) -> Void
  let onOpenLast: (SessionRecord) -> Void
  let onOpenPlan: () -> Void

  public init(model: HomeModel, today: Date = Date(), onStart: @escaping (SessionType) -> Void = { _ in },
              onOpenLast: @escaping (SessionRecord) -> Void = { _ in }, onOpenPlan: @escaping () -> Void = {}) {
    self.model = model
    self.today = today
    self.onStart = onStart
    self.onOpenLast = onOpenLast
    self.onOpenPlan = onOpenPlan
  }

  /// Hero colour: the recommended session's colour while there is no number, violet once there is.
  private var heroType: SessionType { model.state == .none ? model.next.type : .fullSim }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        Wordmark()
        Spacer()
        Text(HistoryFormat.shortDate(today)).font(.system(size: 15, weight: .semibold)).foregroundStyle(PhoneTheme.muted)
      }
      hero
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("How to get better").phoneKicker()
          Text(model.next.line).font(.system(size: 17, weight: .semibold)).foregroundStyle(PhoneTheme.inkText)
            .fixedSize(horizontal: false, vertical: true)
          PrimaryButton(model.next.ctaTitle) { onStart(model.next.type) }
        }
      }
      if let last = model.last {
        Button { onOpenLast(last) } label: {
          PhoneCard {
            VStack(alignment: .leading, spacing: 10) {
              Text("Last session").phoneKicker()
              SessionRowContent(record: last)
            }
          }
        }
        .buttonStyle(.plain)
      }
      Button(action: onOpenPlan) {
        PhoneCard {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Your target").phoneKicker()
              Text(model.setup.summary).font(.system(size: 17, weight: .heavy)).foregroundStyle(PhoneTheme.inkText)
            }
            Spacer()
            Text("\u{203A}").font(.system(size: 28, weight: .semibold)).foregroundStyle(PhoneTheme.muted).accessibilityHidden(true)
          }
        }
      }
      .buttonStyle(.plain)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
  }

  @ViewBuilder private var hero: some View {
    let text = PhoneTheme.sessionText(heroType)
    HeroCard(type: heroType) {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.kicker).phoneKicker(color: text)
        if model.state == .none {
          Text(model.hero).phoneStatement().fixedSize(horizontal: false, vertical: true)
          Text(model.line).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
          ghostBars(color: text)
        } else {
          Text(model.hero).phoneHero()
          Text(model.line).font(.system(size: 17, weight: .semibold))
          if let sub = model.sub {
            Text(sub).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
          }
          if let chip = model.chip {
            Text(chip).font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.ink)
              .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.bone, in: Capsule())
          }
          if model.recent.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
              RecentBars(values: model.recent, colors: model.recentTypes.map { PhoneTheme.sessionColor($0) }, caption: "Lower is better")
              if model.legendTypes.count > 1 {
                HStack(spacing: 8) { ForEach(model.legendTypes) { SessionChip($0) } }
              }
            }
              .padding(14)
              .background(Theme.bone, in: RoundedRectangle(cornerRadius: 14))
              .foregroundStyle(PhoneTheme.muted)
          }
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Outline bars promising the number before there is one.
  private func ghostBars(color: Color) -> some View {
    HStack(alignment: .bottom, spacing: 8) {
      ForEach([0.9, 0.7, 0.55, 0.45, 0.35, 0.3], id: \.self) { f in
        RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
          .frame(height: 64 * f).frame(maxWidth: .infinity)
      }
    }
    .frame(height: 64, alignment: .bottom)
    .padding(.top, 6)
    .accessibilityHidden(true)
  }
}
