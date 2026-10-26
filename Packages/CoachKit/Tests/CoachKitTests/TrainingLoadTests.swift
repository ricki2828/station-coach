import XCTest
@testable import CoachKit

final class TrainingLoadTests: XCTestCase {
  private let cal = TrainingLoad.sampleCalendar
  private let base: Int64 = 1_792_368_000_000 // Mon 19 Oct 2026 00:00 UTC

  private func hr(_ pairs: [(Int64, Int)]) -> HeartRateSeries {
    HeartRateSeries(samples: pairs.map { HeartRateSample(epochMs: base + $0.0, bpm: $0.1) })
  }

  /// A session of one run, 120 s long, so the arithmetic is checkable by hand.
  private func shortRun() -> CoachResult {
    let plan = PlanBuilder.build(division: .openMen, target: 3600, type: .fullSim)
    return CoachResult(plan: plan, splits: [StepSplit(stepIndex: 0, startMs: base, endMs: base + 120_000)], early: true,
                       repTimesMs: [], repCorrection: 0, startedAtEpochMs: base, endedAtEpochMs: base + 120_000)
  }

  private func load(_ load: Double, type: SessionType = .fullSim, at date: Date, id: String = UUID().uuidString) -> LoadSession {
    LoadSession(id: id, date: date, type: type,
                load: SessionLoad(load: load, minutes: 60, hardMinutes: 20, simKm: 8, wallBallReps: 100, stationMetres: 2_480, coverage: 1))
  }

  // MARK: heart rate

  func testParseSkipsHeaderAndBadLines() {
    let s = HeartRateSeries.parse(csv: "epoch_ms,bpm\n1000,120\n\nbad,line\n2000,121.4\n3000\n")
    XCTAssertEqual(s.samples, [HeartRateSample(epochMs: 1000, bpm: 120), HeartRateSample(epochMs: 2000, bpm: 121)])
  }

  func testImplausibleAndSpikeSamplesDropped() {
    let s = HeartRateSeries(samples: [
      HeartRateSample(epochMs: 0, bpm: 150), HeartRateSample(epochMs: 1000, bpm: 230), // over 220
      HeartRateSample(epochMs: 2000, bpm: 210), // +60 within 2 s of the last kept
      HeartRateSample(epochMs: 30_000, bpm: 175), // a big move after a long gap is real
    ])
    XCTAssertEqual(s.samples.map(\.bpm), [150, 175])
  }

  func testGapOverTenSecondsIsUncovered() {
    let s = hr([(0, 100), (60_000, 100)])
    XCTAssertEqual(s.coveredMs(from: base, to: base + 120_000), 20_000)
    XCTAssertEqual(s.coverage(from: base, to: base + 120_000), 20.0 / 120, accuracy: 1e-9)
  }

  func testPeakAverageAtOneHertz() {
    var pairs: [(Int64, Int)] = (0..<60).map { (Int64($0) * 1000, 150) }
    pairs += (60..<100).map { (Int64($0) * 1000, 190) }
    XCTAssertEqual(hr(pairs).peakAverage(), 190)
    XCTAssertNil(hr([(0, 150), (1000, 150)]).peakAverage())
  }

  func testPeakAverageAtTheWatchsFiveSecondCadence() {
    var pairs: [(Int64, Int)] = (0..<100).map { (Int64($0) * 5000, 150) }
    pairs += (100..<110).map { (Int64($0) * 5000, 186) } // 50 s hard
    XCTAssertEqual(hr(pairs).peakAverage(), 186)
    XCTAssertNil(hr([(0, 150), (5000, 150)]).peakAverage())
  }

  func testPeakAverageWithIrregularGaps() {
    var t: Int64 = 0
    var pairs: [(Int64, Int)] = []
    for i in 0..<120 {
      t += Int64(1000 * (1 + (i * 7) % 8)) // 1...8 s
      pairs.append((t, i < 80 ? 140 : 180))
    }
    let peak = hr(pairs).peakAverage()
    XCTAssertNotNil(peak)
    XCTAssertEqual(Double(peak!), 180, accuracy: 1)
  }

  func testALoneArtefactReadingDoesNotMakeAPeak() {
    var pairs: [(Int64, Int)] = (0..<60).map { (Int64($0) * 1000, 150) }
    pairs[30] = (30_000, 205)
    XCTAssertEqual(hr(pairs).peakAverage(), 150)
    var five: [(Int64, Int)] = (0..<60).map { (Int64($0) * 5000, 150) }
    five[30] = (150_000, 205)
    XCTAssertEqual(hr(five).peakAverage(), 150)
  }

  func testParseRejectsNonFiniteValues() {
    let s = HeartRateSeries.parse(csv: "1000,nan\n2000,inf\n3000,-inf\n4000,120\n")
    XCTAssertEqual(s.samples.map(\.bpm), [120])
  }

  // MARK: session load

  func testHeartRateGapsFallBackToStepWeights() {
    // 120 s of run 1. Heart rate covers 20 s at 100 bpm (zone 1); the other 100 s take the run weight 3.5.
    let l = SessionLoad.of(shortRun(), hr: hr([(0, 100), (60_000, 100)]), maxHR: 185)
    XCTAssertEqual(l.load, 20.0 / 60 * 1 + 100.0 / 60 * 3.5, accuracy: 0.001)
    XCTAssertEqual(l.coverage, 20.0 / 120, accuracy: 1e-9)
    XCTAssertEqual(l.basis, .assumed)
  }

  func testNoHeartRateUsesStepWeightsOnly() {
    let l = SessionLoad.of(shortRun(), hr: nil, maxHR: 185)
    XCTAssertEqual(l.load, 2 * 3.5, accuracy: 0.001)
    XCTAssertEqual(l.minutes, 2, accuracy: 1e-9)
    XCTAssertEqual(l.basis, .assumed)
    XCTAssertFalse(l.usedHeartRate)
  }

  func testZoneWeightsFollowMaxHR() {
    // 185 max: 170 bpm is zone 5 (0.92), so one minute is 5 load; against a 220 max it is zone 3.
    let plan = PlanBuilder.build(division: .openMen, target: 3600, type: .fullSim)
    let r = CoachResult(plan: plan, splits: [StepSplit(stepIndex: 0, startMs: base, endMs: base + 60_000)], early: true,
                        repTimesMs: [], repCorrection: 0, startedAtEpochMs: base, endedAtEpochMs: base + 60_000)
    let series = HeartRateSeries(samples: (0..<60).map { HeartRateSample(epochMs: base + Int64($0) * 1000, bpm: 170) })
    XCTAssertEqual(SessionLoad.of(r, hr: series, maxHR: 185).load, 5, accuracy: 0.001)
    XCTAssertEqual(SessionLoad.of(r, hr: series, maxHR: 220).load, 3, accuracy: 0.001)
    XCTAssertEqual(SessionLoad.of(r, hr: series, maxHR: 185).basis, .heartRate)
  }

  func testBasisEdges() {
    func basis(_ c: Double) -> LoadBasis {
      SessionLoad(load: 1, minutes: 1, hardMinutes: 0, simKm: 0, wallBallReps: 0, stationMetres: 0, coverage: c).basis
    }
    XCTAssertEqual(basis(0.19), .assumed)
    XCTAssertEqual(basis(0.2), .mixed)
    XCTAssertEqual(basis(0.79), .mixed)
    XCTAssertEqual(basis(0.8), .heartRate)
  }

  func testPartialSessionAddsNoVolumeForUnfinishedSteps() {
    let full = TrainingLoad.sampleResult(.fullSim)
    var partial = full
    partial.splits = Array(full.splits.prefix(4)) // run 1, SkiErg, run 2, sled push
    partial.splits[3].endMs = nil // sled push started, not finished
    partial.early = true
    partial.endedAtEpochMs = partial.splits[3].startMs + 30_000
    let l = SessionLoad.of(partial, hr: nil, maxHR: 185)
    XCTAssertEqual(l.simKm, 2)
    XCTAssertEqual(l.stationMetres, 1_000)
    let whole = SessionLoad.of(full, hr: nil, maxHR: 185)
    XCTAssertEqual(whole.simKm, 8)
    XCTAssertEqual(whole.stationMetres, 2_480)
  }

  func testCorruptSplitsAreNotRebased() {
    var r = TrainingLoad.sampleResult(.fullSim)
    XCTAssertTrue(r.splitsLookValid)
    r.splits = r.splits.map { StepSplit(stepIndex: $0.stepIndex, startMs: $0.startMs - r.startedAtEpochMs, endMs: $0.endMs.map { $0 - r.startedAtEpochMs }) }
    XCTAssertFalse(r.splitsLookValid)
    let l = SessionLoad.of(r, hr: nil, maxHR: 185)
    XCTAssertEqual(l.load, l.minutes * SessionLoad.genericWeight, accuracy: 0.001)
    XCTAssertEqual(l.simKm, 0)
    let rec = SessionRecord(id: "bad", result: r)
    let good = SessionRecord(id: "good", result: TrainingLoad.sampleResult(.fullSim))
    let sum = TrainingLoad.summarise([LoadInput(record: rec, hr: nil), LoadInput(record: good, hr: nil)], now: Date(timeIntervalSince1970: 1_793_000_000))
    XCTAssertEqual(sum.skippedSessionIds, ["bad"])
    XCTAssertEqual(sum.sessions.map(\.id), ["good"])
  }

  func testWallBallRepsComeFromTheCaller() {
    let r = TrainingLoad.sampleResult(.wallBallFocus)
    XCTAssertEqual(SessionLoad.of(r, hr: nil, maxHR: 185, wallBallReps: 77).wallBallReps, 77)
    XCTAssertEqual(SessionLoad.of(r, hr: nil, maxHR: 185).wallBallReps, r.validReps)
  }

  func testSampleSessionsHaveSensibleLoads() {
    let r = TrainingLoad.sampleResult(.fullSim)
    let withHr = SessionLoad.of(r, hr: TrainingLoad.sampleHeartRate(for: r, .full), maxHR: 185)
    let mixed = SessionLoad.of(r, hr: TrainingLoad.sampleHeartRate(for: r, .mixed), maxHR: 185)
    let none = SessionLoad.of(r, hr: TrainingLoad.sampleHeartRate(for: r, .none), maxHR: 185)
    XCTAssertEqual(withHr.basis, .heartRate)
    XCTAssertEqual(mixed.basis, .mixed)
    XCTAssertEqual(none.basis, .assumed)
    XCTAssertEqual(withHr.minutes, 60, accuracy: 3)
    XCTAssertGreaterThan(withHr.load, none.load)
    XCTAssertTrue((150...320).contains(withHr.load), "\(withHr.load)")
    XCTAssertTrue((150...320).contains(none.load), "\(none.load)")
  }

  // MARK: max heart rate

  private func session(_ daysAgo: Double, peak: Int?, now: Date) -> HeartRateSession {
    let t = Int64(now.timeIntervalSince1970 * 1000)
    let series = peak.map { p in HeartRateSeries(samples: (0..<40).map { HeartRateSample(epochMs: t + Int64($0) * 1000, bpm: p) }) }
    return HeartRateSession(date: now.addingTimeInterval(-daysAgo * 86_400), series: series)
  }

  func testMaxHRAssumedUntilThreeSessions() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let two = MaxHeartRate.estimate([session(1, peak: 190, now: now), session(2, peak: 188, now: now)], now: now)
    XCTAssertEqual(two.bpm, 185)
    XCTAssertTrue(two.estimated)
    XCTAssertTrue(two.words.contains("assumed"))
    let none = MaxHeartRate.estimate([session(1, peak: nil, now: now)], now: now)
    XCTAssertEqual(none.sessionsWithHeartRate, 0)
  }

  func testMaxHRIsBestPeakAndNeverDropsWithAnEasierSession() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let three = [session(1, peak: 178, now: now), session(5, peak: 190, now: now), session(9, peak: 181, now: now)]
    let m = MaxHeartRate.estimate(three, now: now)
    XCTAssertEqual(m.bpm, 181) // 190 has no second session within 5 bpm, so the second-highest peak stands
    XCTAssertFalse(m.estimated)
    XCTAssertTrue(m.words.contains("from your sessions"))
    let more = MaxHeartRate.estimate([session(0, peak: 150, now: now)] + three, now: now)
    XCTAssertEqual(more.bpm, 181)
  }

  func testOneArtefactSessionDoesNotSetMax() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let s = [session(1, peak: 210, now: now), session(3, peak: 188, now: now), session(5, peak: 187, now: now), session(7, peak: 189, now: now)]
    XCTAssertEqual(MaxHeartRate.estimate(s, now: now).bpm, 189)
    // Two sessions that agree within 5 bpm do set it.
    let two = [session(1, peak: 192, now: now), session(3, peak: 189, now: now), session(5, peak: 180, now: now)]
    XCTAssertEqual(MaxHeartRate.estimate(two, now: now).bpm, 192)
  }

  func testMaxHRAtFiveSecondCadence() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let t = Int64(now.timeIntervalSince1970 * 1000)
    let five = (0..<40).map { HeartRateSample(epochMs: t + Int64($0) * 5000, bpm: 184) }
    let sessions = (1...3).map { HeartRateSession(date: now.addingTimeInterval(-Double($0) * 86_400), series: HeartRateSeries(samples: five)) }
    let m = MaxHeartRate.estimate(sessions, now: now)
    XCTAssertEqual(m.bpm, 184)
    XCTAssertFalse(m.estimated)
  }

  func testMaxHRIgnoresSessionsOlderThan180Days() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let s = [session(200, peak: 199, now: now), session(1, peak: 178, now: now), session(2, peak: 176, now: now), session(3, peak: 180, now: now)]
    XCTAssertEqual(MaxHeartRate.estimate(s, now: now).bpm, 180)
    XCTAssertEqual(MaxHeartRate.estimate(Array(s.prefix(3)), now: now).bpm, 185) // only two in the window
  }

  // MARK: bands

  func testBandEdges() {
    XCTAssertEqual(LoadBand.of(ratio: 0.79), .lighter)
    XCTAssertEqual(LoadBand.of(ratio: 0.8), .usual)
    XCTAssertEqual(LoadBand.of(ratio: 1.1), .usual)
    XCTAssertEqual(LoadBand.of(ratio: 1.11), .stepUp)
    XCTAssertEqual(LoadBand.of(ratio: 1.3), .stepUp)
    XCTAssertEqual(LoadBand.of(ratio: 1.31), .bigJump)
    XCTAssertEqual(LoadBand.of(ratio: 1.9), .bigJump)
  }

  func testSampleScenariosLandInTheirStates() {
    XCTAssertEqual(TrainingLoad.sample(.usual).compare.state, .compared(.usual))
    XCTAssertEqual(TrainingLoad.sample(.stepUp).compare.state, .compared(.stepUp))
    XCTAssertEqual(TrainingLoad.sample(.bigJump).compare.state, .compared(.bigJump))
    XCTAssertEqual(TrainingLoad.sample(.lighter).compare.state, .compared(.lighter))
    XCTAssertEqual(TrainingLoad.sample(.firstWeeks).compare.state, .firstWeeks)
    XCTAssertEqual(TrainingLoad.sample(.returning).compare.state, .returning)
    XCTAssertEqual(TrainingLoad.sample(.noHeartRate).compare.state, .compared(.usual))
    XCTAssertEqual(TrainingLoad.sample(.mixedHeartRate).compare.state, .compared(.usual))
  }

  func testBigJumpIsAboutDouble() {
    let c = TrainingLoad.sample(.bigJump).compare
    XCTAssertTrue(c.isDouble)
    XCTAssertEqual(c.usualRounded, 480)
    XCTAssertEqual(c.current.loadRounded, 960)
  }

  func testNoSessionsWeek() {
    let d = TrainingLoad.sample(.usual)
    let next = cal.date(byAdding: .weekOfYear, value: 1, to: d.weekStart)!
    let c = LoadCompare.compare(d.sessions, periodStart: next, calendar: cal)
    XCTAssertEqual(c.state, .noSessions)
    XCTAssertEqual(LoadWords.headline(c), "No sessions this week.")
    XCTAssertNil(WeeklyNotice.content(for: c))
  }

  func testWeeksBeforeFirstSessionDoNotCountAndEmptyWeeksDo() {
    let mon = Date(timeIntervalSince1970: 1_792_368_000)
    func at(_ weeks: Int, _ day: Int = 1) -> Date { cal.date(byAdding: .day, value: weeks * 7 + day, to: mon)! }
    // First session two weeks ago, then three in total across two weeks, one empty week between: usual is the mean of 3 counted weeks.
    let s = [load(300, at: at(-3)), load(300, at: at(-3, 3)), load(300, at: at(-1)), load(600, at: at(0))]
    let c = LoadCompare.compare(s, periodStart: mon, calendar: cal)
    // Counted weeks: -3 (600), -2 (0), -1 (300); the week -4 is before the first session.
    XCTAssertEqual(c.usualRounded, 300)
    XCTAssertEqual(c.state, .compared(.bigJump))
  }

  func testFirstWeeksNeedThreeSessionsInTwoWeeks() {
    let mon = Date(timeIntervalSince1970: 1_792_368_000)
    func at(_ weeks: Int, _ day: Int = 1) -> Date { cal.date(byAdding: .day, value: weeks * 7 + day, to: mon)! }
    let oneWeek = [load(300, at: at(-1)), load(300, at: at(-1, 3)), load(300, at: at(-1, 5)), load(300, at: at(0))]
    XCTAssertEqual(LoadCompare.compare(oneWeek, periodStart: mon, calendar: cal).state, .firstWeeks)
    let twoWeeks = [load(300, at: at(-2)), load(300, at: at(-1)), load(300, at: at(-1, 3)), load(450, at: at(0))]
    XCTAssertEqual(LoadCompare.compare(twoWeeks, periodStart: mon, calendar: cal).state, .compared(.usual))
  }

  func testWeekBoundaryIsMondayMidnightLocal() {
    let sydney = LoadHistory.calendar(timeZone: TimeZone(identifier: "Australia/Sydney")!)
    // Sun 25 Oct 2026 is before the clocks change (4 Oct) so Sydney is UTC+11. Monday 26 Oct 00:00 local = Sun 13:00 UTC.
    let mondayLocal = sydney.date(from: DateComponents(year: 2026, month: 10, day: 26))!
    let sundayLate = mondayLocal.addingTimeInterval(-60) // Sun 23:59 local
    let weeks = LoadHistory.weeks([load(100, at: sundayLate), load(200, at: mondayLocal)], now: mondayLocal, count: 2, calendar: sydney)
    XCTAssertEqual(weeks.map(\.loadRounded), [100, 200])
    XCTAssertEqual(sydney.component(.weekday, from: weeks[1].start), 2)
  }

  // MARK: months and years

  func testMonthsAndYear() {
    let jan = cal.date(from: DateComponents(year: 2026, month: 1, day: 10))!
    let mar = cal.date(from: DateComponents(year: 2026, month: 3, day: 2))!
    let s = [load(100, at: jan), load(150, at: jan.addingTimeInterval(86_400)), load(300, at: mar)]
    let year = LoadHistory.year(s, year: 2026, calendar: cal)
    XCTAssertEqual(year.count, 12)
    XCTAssertEqual(year.map(\.sessions), [2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    let months = LoadHistory.months(s, now: mar, count: 3, calendar: cal)
    XCTAssertEqual(months.map(\.loadRounded), [250, 0, 300])
  }

  func testSessionsYearToDateAgainstLastYear() {
    let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
    let s = [load(1, at: d(2026, 2, 1)), load(1, at: d(2026, 5, 1)), load(1, at: d(2025, 3, 1)), load(1, at: d(2025, 9, 1))]
    let r = LoadHistory.sessionsYearToDate(s, now: now, calendar: cal)
    XCTAssertEqual(r.thisYear, 2)
    XCTAssertEqual(r.lastYear, 1)
    XCTAssertEqual(LoadWords.yearVsLast(thisYear: 5, lastYear: 3), "2 more sessions than this time last year")
    XCTAssertNil(LoadWords.yearVsLast(thisYear: 5, lastYear: 0))
  }

  // MARK: words

  func testHeadlinesDifferPerBand() {
    let kinds: [LoadSample] = [.usual, .stepUp, .bigJump, .lighter, .firstWeeks, .returning]
    let lines = kinds.map { LoadWords.headline(TrainingLoad.sample($0).compare) }
    XCTAssertEqual(Set(lines).count, lines.count)
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.usual).compare), "480 load, about your usual week (480).")
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.stepUp).compare), "600 load, 25% more than your usual week (480).")
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.bigJump).compare), "960 load, about double your usual week (480).")
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.lighter).compare), "240 load, 50% less than your usual week (480).")
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.firstWeeks).compare), "360 load. Your usual week takes shape after 3 sessions.")
    XCTAssertEqual(LoadWords.headline(TrainingLoad.sample(.returning).compare), "240 load, your first week back. We compare from next week.")
  }

  func testBandWordsAndWhatChanged() {
    XCTAssertEqual(LoadWords.bandWords(TrainingLoad.sample(.usual).compare), "About your usual week")
    XCTAssertEqual(LoadWords.bandWords(TrainingLoad.sample(.bigJump).compare), "About double your usual week")
    XCTAssertNil(LoadWords.bandWords(TrainingLoad.sample(.firstWeeks).compare))
    XCTAssertEqual(LoadWords.whatChanged(TrainingLoad.sample(.bigJump).compare), "4 full sims, usual 2.")
    XCTAssertEqual(LoadWords.whatChanged(TrainingLoad.sample(.lighter).compare), "1 full sim, usual 2.")
    XCTAssertEqual(LoadWords.whatChanged(TrainingLoad.sample(.usual).compare), "120 work minutes, usual 120.")
    XCTAssertNil(LoadWords.whatChanged(TrainingLoad.sample(.returning).compare))
  }

  func testSuggestions() {
    let line = "Time for a full sim. It's the real test of the fade."
    func s(_ k: LoadSample) -> String? { LoadWords.suggestion(TrainingLoad.sample(k).compare, usualLine: line) }
    XCTAssertEqual(s(.bigJump), "Big week. Keep next week near 530 and make one session a half sim.")
    XCTAssertEqual(s(.stepUp), "Good step. Hold here a week before adding a session.")
    XCTAssertEqual(s(.usual), line)
    XCTAssertEqual(s(.lighter), "Lighter week. Back to about 480 next week is fine.")
    XCTAssertEqual(s(.firstWeeks), "Three sessions in and this compares you with your own usual.")
    XCTAssertNil(s(.returning))
  }

  func testFootnoteAndHeartRateLine() {
    let noHr = TrainingLoad.sample(.noHeartRate)
    let week = noHr.weeks.last!
    XCTAssertEqual(LoadWords.footnote(week), LoadWords.assumedFootnote)
    XCTAssertEqual(LoadWords.heartRateSessionsLine(week), "0 of 2 sessions used your heart rate.")
    XCTAssertNil(LoadWords.footnote(TrainingLoad.sample(.usual).weeks.last!))
    XCTAssertEqual(LoadWords.heartRateSessionsLine(TrainingLoad.sample(.usual).weeks.last!), "2 of 2 sessions used your heart rate.")
  }

  func testNumberGrouping() {
    XCTAssertEqual(LoadWords.number(486), "486")
    XCTAssertEqual(LoadWords.number(1_234), "1,234")
    XCTAssertEqual(LoadWords.number(1_234_567), "1,234,567")
  }

  // MARK: notification

  func testNoticeStringsPerBand() {
    func n(_ k: LoadSample, unsent: Bool = false) -> WeeklyNotice.Content? { WeeklyNotice.content(for: TrainingLoad.sample(k).compare, watchHasUnsent: unsent) }
    XCTAssertEqual(n(.usual)?.title, "Your week: 480 load")
    XCTAssertEqual(n(.usual)?.body, "480 load, about your usual week. Tap for what changed.")
    XCTAssertEqual(n(.stepUp)?.body, "600 load, 25% more than your usual week. Tap for what changed.")
    XCTAssertEqual(n(.bigJump)?.body, "960 load, about double your usual week. Tap for what changed.")
    XCTAssertEqual(n(.lighter)?.body, "240 load, 50% less than your usual week. Tap for what changed.")
    XCTAssertEqual(n(.returning)?.body, "240 load, your first week back. We compare from next week. Tap for what changed.")
    XCTAssertEqual(n(.usual, unsent: true)?.body, "480 load, about your usual week. Tap for what changed. (sync your watch for the full week)")
  }

  func testNoticeSkips() {
    // A first week with fewer than 2 sessions says nothing; with 2 it does.
    let mon = Date(timeIntervalSince1970: 1_792_368_000)
    let one = LoadCompare.compare([load(300, at: mon.addingTimeInterval(86_400))], periodStart: mon, calendar: cal)
    XCTAssertEqual(one.state, .firstWeeks)
    XCTAssertNil(WeeklyNotice.content(for: one))
    XCTAssertNotNil(WeeklyNotice.content(for: TrainingLoad.sample(.firstWeeks).compare))
  }

  func testPeriodHelpers() {
    let w = TrainingLoad.sample(.stepUp).weeks.last!
    XCTAssertEqual(w.sessions, 3)
    XCTAssertEqual(w.fullSims, 2)
    XCTAssertEqual(w.dominantType, .fullSim)
    XCTAssertEqual(w.loadByType[.halfSim], 120)
    XCTAssertEqual(w.simKm, 20)
    XCTAssertEqual(TrainingLoad.sample(.stepUp).weeks.count, 6)
  }
}
