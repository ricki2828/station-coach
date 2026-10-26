import CoachKit
import SwiftUI

extension ScreenCatalog {
  private static func loadW(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view.frame(width: Theme.phone.width)))
  }

  private static func onPaper(_ v: some View) -> some View { v.padding(20).background(PhoneTheme.paper) }

  /// Describes, never orders (the coach's own wording arrives with the app wiring).
  static let loadUsualLine = "About your usual week. The next full sim is the real test of the fade."

  static func loadSummary(_ s: LoadSample, onWhy: @escaping () -> Void = {}) -> WeeklySummaryScreen {
    let d = TrainingLoad.sample(s)
    return WeeklySummaryScreen(compare: d.compare, weeks: d.weeks, calendar: d.calendar, usualLine: loadUsualLine, onWhy: onWhy)
  }

  private static func demoLoad(_ t: SessionType, _ jitter: Int) -> SessionLoad {
    let j = Double(jitter)
    switch t {
    case .fullSim: return SessionLoad(load: 230 + j * 6, minutes: 58 + j, hardMinutes: 26 + j / 2, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: 1)
    case .halfSim: return SessionLoad(load: 115 + j * 3, minutes: 29 + j / 2, hardMinutes: 11 + j / 3, simKm: 4, wallBallReps: 0, stationMetres: 1_180, coverage: 1)
    case .wallBallFocus: return SessionLoad(load: 96 + j * 3, minutes: 27, hardMinutes: 9, simKm: 3, wallBallReps: 150, stationMetres: 0, coverage: 1)
    }
  }

  /// Synthetic history, Monday 3 Nov 2025 to now: a quieter year before, a steady build this year, a short break in January.
  /// Last year (2025, Nov-Dec) only has the tail, so the year-vs-last line compares the same stretch honestly.
  static func demoHistory(now: Date, calendar: Calendar) -> [LoadSession] {
    let firstMonday = Date(timeIntervalSince1970: 1_762_128_000)  // Mon 3 Nov 2025
    let cycle = [1, 1, 2, 1, 0, 0, 1, 2, 2, 2, 1, 2, 2, 3, 2, 2, 2, 1, 2, 3, 2, 2, 2, 3, 2, 2, 1, 2, 3, 2]
    let perWeek = (0..<53).map { cycle[$0 % cycle.count] }
    let types: [SessionType] = [.fullSim, .halfSim, .fullSim, .wallBallFocus, .fullSim, .halfSim]
    let days = [1, 3, 5]
    var out: [LoadSession] = []
    for (w, n) in perWeek.enumerated() {
      for i in 0..<n {
        let date = calendar.date(byAdding: .day, value: w * 7 + days[i], to: firstMonday)!.addingTimeInterval(10 * 3_600)
        guard date < now else { continue }
        let type = types[(w + i) % types.count]
        out.append(LoadSession(id: "demo-\(w)-\(i)", date: date, type: type, load: demoLoad(type, (w * 3 + i * 5) % 9)))
      }
    }
    return out
  }

  /// Year view needs last year to compare against: add Jan-Oct 2025 as a lighter year.
  static func demoHistoryWithLastYear(now: Date, calendar: Calendar) -> [LoadSession] {
    let jan = Date(timeIntervalSince1970: 1_735_516_800)  // Mon 30 Dec 2024
    let types: [SessionType] = [.halfSim, .fullSim, .halfSim, .wallBallFocus]
    var out: [LoadSession] = []
    for w in 0..<44 where w % 5 != 4 {
      let date = calendar.date(byAdding: .day, value: w * 7 + 2, to: jan)!.addingTimeInterval(10 * 3_600)
      let type = types[w % types.count]
      out.append(LoadSession(id: "demo-ly-\(w)", date: date, type: type, load: demoLoad(type, w % 7)))
    }
    return out + demoHistory(now: now, calendar: calendar)
  }

  public static var loadScreens: [CatalogEntry] {
    let usual = TrainingLoad.sample(.usual)
    let first = TrainingLoad.sample(.firstWeeks)
    let cal = usual.calendar
    let demo = demoHistory(now: usual.now, calendar: cal)
    let demoLY = demoHistoryWithLastYear(now: usual.now, calendar: cal)
    let oneNow = usual.weekStart.addingTimeInterval(36_000 + 3_600)
    let one = LoadSession(id: "one", date: usual.weekStart.addingTimeInterval(36_000), type: .fullSim, load: demoLoad(.fullSim, 0))
    let why = TrainingLoad.sample(.mixedHeartRate)
    func card(_ d: LoadSampleData, note: String? = nil) -> WeekCard {
      WeekCard(period: d.weeksSoFar[d.weeksSoFar.count - 1], bars: LoadBar.bars(d.weeksSoFar, calendar: d.calendar), note: note)
    }
    return [
      loadW("week-summary-usual", loadSummary(.usual)),
      loadW("week-summary-stepup", loadSummary(.stepUp)),
      loadW("week-summary-bigjump", loadSummary(.bigJump)),
      loadW("week-summary-lighter", loadSummary(.lighter)),
      loadW("week-summary-first", loadSummary(.firstWeeks)),
      loadW("week-summary-returning", loadSummary(.returning)),
      loadW("week-summary-nohr", loadSummary(.noHeartRate)),
      loadW("week-summary-xl", loadSummary(.bigJump).environment(\.dynamicTypeSize, .xxxLarge)),
      loadW("week-why", WhyLoadSheet(period: why.compare.current, maxHR: MaxHeartRate.estimate([], now: why.now))),
      loadW("week-card-sofar", onPaper(card(usual))),
      loadW("week-card-first", onPaper(card(first, note: "Your usual week takes shape after 3 sessions."))),
      loadW("totals-week", onPaper(TrainingTotalsCard(mode: .week, sessions: demo, now: usual.now, calendar: cal))),
      loadW("totals-month", onPaper(TrainingTotalsCard(mode: .month, sessions: demo, now: usual.now, calendar: cal, bestFade: 19))),
      loadW("totals-year", onPaper(TrainingTotalsCard(mode: .year, sessions: demo, now: usual.now, calendar: cal))),
      loadW("totals-year-vs-last", onPaper(TrainingTotalsCard(mode: .year, sessions: demoLY, now: usual.now, calendar: cal))),
      loadW("totals-one-session", onPaper(TrainingTotalsCard(mode: .week, sessions: [one], now: oneNow, calendar: cal))),
      loadW("notify-optin", onPaper(NotifyOptInCard())),
    ]
  }
}
