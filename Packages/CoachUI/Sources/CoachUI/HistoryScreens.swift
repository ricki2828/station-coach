import CoachKit
import SwiftUI

/// "Sat 24 Oct", total, words against target, strip. Shared by Home's last-session card and the History list.
struct SessionRowContent: View {
  let record: SessionRecord

  var body: some View {
    let r = record.result
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        SessionChip(record.type)
        Spacer()
        Text(HistoryFormat.shortDate(record.date)).scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
      }
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(Fmt.clock(r.totalSeconds)).scaledStat().foregroundStyle(PhoneTheme.inkText)
        if let words = record.targetWords {
          Text(words.text).scaledFont(15, .semibold).foregroundStyle(words.over ? PhoneTheme.amberText : PhoneTheme.inkText)
        } else {
          Text("\(r.completedStationCount) of \(r.plan.stationCount) stations").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
        }
      }
      StationStrip(result: r, height: 8)
    }
    .accessibilityElement(children: .combine)
  }
}

public struct HistoryScreen: View {
  let records: [SessionRecord]
  let syncPercent: Int?
  let onOpen: (SessionRecord) -> Void
  let onRawFiles: () -> Void
  let totals: AnyView?

  /// `totals` is the Week / Month / Year card, shown above the list once there is a session.
  public init(records: [SessionRecord], syncPercent: Int? = nil, totals: AnyView? = nil, onOpen: @escaping (SessionRecord) -> Void = { _ in },
              onRawFiles: @escaping () -> Void = {}) {
    self.totals = totals
    self.records = SessionRecord.sorted(records)
    self.syncPercent = syncPercent
    self.onOpen = onOpen
    self.onRawFiles = onRawFiles
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("History").scaledStatement(size: 34).foregroundStyle(PhoneTheme.inkText)
        Spacer()
        TextLinkButton("Raw files", action: onRawFiles)
      }
      if let p = syncPercent {
        PhoneCard {
          VStack(alignment: .leading, spacing: 10) {
            Text("Syncing from watch\u{2026} \(p)%").scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText)
            // Drawn, not ProgressView: ImageRenderer cannot render the UIKit-backed control.
            GeometryReader { geo in
              ZStack(alignment: .leading) {
                Capsule().fill(PhoneTheme.hairline)
                Capsule().fill(PhoneTheme.inkText).frame(width: geo.size.width * Double(min(max(p, 0), 100)) / 100)
              }
            }
            .frame(height: 8)
          }
        }
        .accessibilityElement(children: .combine)
      }
      if !records.isEmpty, let totals { totals }
      if records.isEmpty && syncPercent == nil {
        PhoneCard {
          Text("No sessions yet. Your first lands here after you finish on the watch.")
            .scaledFont(17, .semibold).foregroundStyle(PhoneTheme.muted)
        }
      }
      ForEach(records) { rec in
        Button { onOpen(rec) } label: { PhoneCard { SessionRowContent(record: rec) } }.buttonStyle(.plain)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
  }
}

/// "45 s over" / "25 s under" once |delta| is 5 s or more, else "on plan".
enum DeltaWords {
  static func text(_ d: Int) -> (text: String, over: Bool?) {
    guard abs(d) >= 5 else { return ("on plan", nil) }
    let amount = abs(d) < 60 ? "\(abs(d)) s" : Fmt.gap(d)
    return (d > 0 ? "\(amount) over" : "\(amount) under", d > 0)
  }
}

/// Light session detail: coloured header, where the time went, run fade bars, wall-ball sets, share.
public struct SessionDetailScreen: View {
  let record: SessionRecord
  let onShare: () -> Void
  let onExport: () -> Void
  let onSaveCount: ((WallBallEdit) -> Bool)?
  @State private var editing = false
  @State private var saveFailed = false

  /// `onSaveCount` non-nil shows the "Edit count" link; the no-rep count comes from `record.result`.
  public init(record: SessionRecord, onSaveCount: ((WallBallEdit) -> Bool)? = nil,
              onShare: @escaping () -> Void = {}, onExport: @escaping () -> Void = {}) {
    self.record = record
    self.onSaveCount = onSaveCount
    self.onShare = onShare
    self.onExport = onExport
  }

  public var body: some View {
    let r = record.result
    let insight = InsightPicker.pick(r)
    let sets = r.wallBallSets()
    VStack(alignment: .leading, spacing: 20) {
      HeroCard(type: record.type) {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(record.type.title) \u{00B7} \(HistoryFormat.shortDate(record.date))").scaledKicker(color: PhoneTheme.sessionText(record.type))
          Text(insight.headline).scaledFont(30, .heavy).fontWidth(.condensed)
          Text(Fmt.clock(r.totalSeconds)).scaledHero()
          if let words = record.targetWords {
            Text(words.text).scaledFont(17, .semibold)
          } else {
            Text("\(r.completedStationCount) of \(r.plan.stationCount) stations").scaledFont(17, .semibold)
          }
        }
      }
      PhoneCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("Where the time went").scaledKicker()
          ForEach(r.rows.filter { !$0.step.isRun }, id: \.step.index) { row in stationRow(row) }
        }
      }
      let slows = RunFade.slowdowns(r)
      if !slows.isEmpty {
        PhoneCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("Runs after each station").scaledKicker()
            RecentBars(values: slows.map { max(0, $0.seconds) }, colors: slows.map { PhoneTheme.stationColor($0.afterActivity) }, caption: "Taller = slower. Run 1 is the baseline.")
            HStack(spacing: 8) {
              ForEach(Array(slows.enumerated()), id: \.offset) { _, s in
                Text(StationStrip.shortName(s.afterActivity)).scaledFont(11, .bold).foregroundStyle(PhoneTheme.muted)
                  .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
              }
            }
          }
        }
      }
      if !sets.isEmpty {
        PhoneCard {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Wall-ball sets").scaledKicker()
              Spacer()
              if onSaveCount != nil { TextLinkButton("Edit count") { editing = true } }
            }
            if record.result.noRepCount > 0 {
              Text(record.result.noRepCount == 1 ? "1 no-rep" : "\(record.result.noRepCount) no-reps").scaledFont(17, .heavy).foregroundStyle(PhoneTheme.amberText)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .top)], alignment: .leading, spacing: 10) {
              ForEach(Array(sets.enumerated()), id: \.offset) { _, s in
                VStack(spacing: 2) {
                  Text("\(s.reps)").scaledFont(17, .heavy).foregroundStyle(Theme.ink)
                    .frame(width: 48, height: 32).background(PhoneTheme.sessionColor(.wallBallFocus), in: Capsule())
                  Text(s.restBeforeSeconds > 0 ? "\(s.restBeforeSeconds) s rest" : "first").scaledFont(12, .semibold).foregroundStyle(PhoneTheme.muted)
                }
              }
            }
            Text("Rep count is an estimate.").scaledFont(13, .semibold).foregroundStyle(PhoneTheme.muted)
          }
        }
      }
      VStack(spacing: 4) {
        PrimaryButton("Share card", action: onShare)
        TextLinkButton("Export data", action: onExport).frame(maxWidth: .infinity)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
    .sheet(isPresented: $editing, onDismiss: { saveFailed = false }) {
      WallBallEditSheet(initial: WallBallCountAdapter.initial(for: record),
                        errorText: saveFailed ? "Couldn't save. Try again." : nil,
                        onSave: { edit in
                          if onSaveCount?(edit) ?? true { saveFailed = false; editing = false } else { saveFailed = true }
                        },
                        onCancel: { saveFailed = false; editing = false })
        .presentationDetents([.medium])
    }
  }

  private func stationRow(_ row: CoachResult.Row) -> some View {
    HStack(spacing: 10) {
      Circle().fill(PhoneTheme.stationColor(row.step.activity)).frame(width: 12, height: 12)
      // Same type size on every row: when the full name does not fit, burpee broad jumps become "BBJ".
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { nameText(row.step.name); trailing(row) }
        HStack(spacing: 8) { nameText(row.step.activity == .burpeeBroadJump ? "BBJ" : row.step.name); trailing(row) }
        // Largest text sizes: let the name wrap rather than clip.
        HStack(spacing: 8) { Text(row.step.name).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).lineLimit(2); trailing(row) }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.rowLabel(row))
  }

  /// "Sled push, 4:04, 20 s over": the full name, never the BBJ short label, with the time and the delta.
  static func rowLabel(_ row: CoachResult.Row) -> String {
    guard let actual = row.actualSeconds, let d = row.deltaSeconds else { return "\(row.step.name), not done" }
    return "\(row.step.name), \(Fmt.clock(actual)), \(DeltaWords.text(d).text)"
  }

  private func nameText(_ s: String) -> some View {
    Text(s).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText).lineLimit(1).fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder private func trailing(_ row: CoachResult.Row) -> some View {
    Spacer(minLength: 8)
    if let actual = row.actualSeconds, let d = row.deltaSeconds {
      let w = DeltaWords.text(d)
      Text(w.text).scaledFont(15, .semibold).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(w.over == nil ? PhoneTheme.muted : w.over! ? PhoneTheme.amberText : PhoneTheme.inkText)
      Text(Fmt.clock(actual)).scaledFont(20, .semibold).monospacedDigit().foregroundStyle(PhoneTheme.inkText)
        .frame(minWidth: 64, alignment: .trailing)
    } else {
      Text("not done").scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted)
    }
  }
}
