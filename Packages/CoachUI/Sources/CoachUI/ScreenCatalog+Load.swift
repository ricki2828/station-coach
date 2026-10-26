import CoachKit
import SwiftUI

extension ScreenCatalog {
  private static func loadW(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view.frame(width: Theme.phone.width)))
  }

  static let loadUsualLine = "Time for a full sim. It's the real test of the fade."

  static func loadSummary(_ s: LoadSample, onWhy: @escaping () -> Void = {}) -> WeeklySummaryScreen {
    let d = TrainingLoad.sample(s)
    return WeeklySummaryScreen(compare: d.compare, weeks: d.weeks, calendar: d.calendar, usualLine: loadUsualLine, onWhy: onWhy)
  }

  /// The sample's final week with only its first session, as a week still in progress.
  static func loadSoFar(_ s: LoadSample) -> (data: LoadSampleData, sessions: [LoadSession], period: LoadPeriod, bars: [LoadBar]) {
    let d = TrainingLoad.sample(s)
    let next = d.calendar.date(byAdding: .weekOfYear, value: 1, to: d.weekStart) ?? d.weekStart
    let thisWeek = d.sessions.filter { $0.date >= d.weekStart && $0.date < next }.sorted { $0.date < $1.date }
    let kept = d.sessions.filter { x in !(x.date >= d.weekStart) } + thisWeek.prefix(1)
    let weeks = LoadHistory.weeks(kept, now: d.weekStart, count: 6, calendar: d.calendar)
    return (d, kept, weeks[weeks.count - 1], LoadBar.bars(weeks, calendar: d.calendar, currentSoFar: true))
  }

  /// Sample sessions plus a run of earlier-year sessions, for the year-versus-last-year line.
  static func loadWithLastYear() -> (sessions: [LoadSession], data: LoadSampleData) {
    let d = TrainingLoad.sample(.usual)
    var out = d.sessions
    let load = SessionLoad(load: 240, minutes: 60, hardMinutes: 28, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: 1)
    var date = d.calendar.date(byAdding: .year, value: -1, to: d.weekStart.addingTimeInterval(-70 * 86_400)) ?? d.weekStart
    for i in 0..<14 {
      out.append(LoadSession(id: "last-\(i)", date: date, type: i % 3 == 0 ? .halfSim : .fullSim, load: load))
      date = date.addingTimeInterval(7 * 86_400)
    }
    return (out, d)
  }

  public static var loadScreens: [CatalogEntry] {
    let usual = TrainingLoad.sample(.usual)
    let sofar = loadSoFar(.usual)
    let firstSoFar = loadSoFar(.firstWeeks)
    let last = loadWithLastYear()
    let one = LoadSession(id: "one", date: usual.weekStart.addingTimeInterval(36_000), type: .fullSim,
                          load: SessionLoad(load: 240, minutes: 60, hardMinutes: 28, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: 1))
    let why = TrainingLoad.sample(.mixedHeartRate)
    return [
      loadW("week-summary-usual", loadSummary(.usual)),
      loadW("week-summary-stepup", loadSummary(.stepUp)),
      loadW("week-summary-bigjump", loadSummary(.bigJump)),
      loadW("week-summary-lighter", loadSummary(.lighter)),
      loadW("week-summary-first", loadSummary(.firstWeeks)),
      loadW("week-summary-returning", loadSummary(.returning)),
      loadW("week-summary-nohr", loadSummary(.noHeartRate)),
      loadW("week-summary-xl", loadSummary(.bigJump).environment(\.dynamicTypeSize, .xxxLarge)),
      loadW("week-why", WhyLoadSheet(period: why.compare.current, maxHR: MaxHeartRate.estimate([], now: why.weekStart))),
      loadW("week-card-sofar", WeekCard(period: sofar.period, bars: sofar.bars, soFar: true).padding(20).background(PhoneTheme.paper)),
      loadW("week-card-first", WeekCard(period: firstSoFar.period, bars: firstSoFar.bars, soFar: true,
                                       note: "Your usual week takes shape after 3 sessions.").padding(20).background(PhoneTheme.paper)),
      loadW("totals-week", TrainingTotalsCard(mode: .week, sessions: usual.sessions, now: usual.weekStart.addingTimeInterval(3 * 86_400), calendar: usual.calendar).padding(20).background(PhoneTheme.paper)),
      loadW("totals-month", TrainingTotalsCard(mode: .month, sessions: usual.sessions, now: usual.weekStart.addingTimeInterval(3 * 86_400), calendar: usual.calendar, bestFade: 19).padding(20).background(PhoneTheme.paper)),
      loadW("totals-year", TrainingTotalsCard(mode: .year, sessions: usual.sessions, now: usual.weekStart.addingTimeInterval(3 * 86_400), calendar: usual.calendar).padding(20).background(PhoneTheme.paper)),
      loadW("totals-year-vs-last", TrainingTotalsCard(mode: .year, sessions: last.sessions, now: last.data.weekStart.addingTimeInterval(3 * 86_400), calendar: last.data.calendar).padding(20).background(PhoneTheme.paper)),
      loadW("totals-one-session", TrainingTotalsCard(mode: .week, sessions: [one], now: usual.weekStart.addingTimeInterval(3 * 86_400), calendar: usual.calendar).padding(20).background(PhoneTheme.paper)),
      loadW("notify-optin", NotifyOptInCard().padding(20).background(PhoneTheme.paper)),
    ]
  }
}
