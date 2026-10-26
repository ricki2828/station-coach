import XCTest
@testable import CoachKit

final class CoachHistoryTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_016_000)

  /// Full-sim style plan where every run 2..8 takes `extra` more than its target and the rest are on target.
  private func record(_ id: String, _ type: SessionType = .fullSim, day: Int64 = 0, fade: Int?, total: Int = 0, until: Int? = nil, wallBallsExtra: Int = 0) -> SessionRecord {
    let plan = PlanBuilder.build(division: .openMen, target: 5400, type: type)
    let start = (1_792_836_000 + day * 86_400) * 1000
    var t = start
    var splits: [StepSplit] = []
    for step in plan.steps {
      if let until, step.index >= until { break }
      var extra = total
      if step.isRun, (step.runNumber ?? 0) > 1 { extra += (fade ?? 0) + plan.transitionSeconds }
      if step.activity == .wallBalls { extra += wallBallsExtra }
      let d = Int64(step.targetSeconds + extra) * 1000
      splits.append(StepSplit(stepIndex: step.index, startMs: t, endMs: t + d))
      t += d
    }
    return SessionRecord(id: id, result: CoachResult(plan: plan, splits: splits, early: until != nil, repTimesMs: [], repCorrection: 0,
                                                      startedAtEpochMs: start, endedAtEpochMs: t))
  }

  func testFadeIsMeanOfRunSlowdowns() {
    XCTAssertEqual(record("a", fade: 27).fade, 27)
    XCTAssertEqual(record("a", fade: 0).fade, 0)
  }

  func testFadeNilWithFewerThanTwoRuns() {
    XCTAssertNil(record("a", fade: 20, until: 2).fade)
    XCTAssertNil(record("a", fade: 20, until: 1).fade)
  }

  func testInsightRuleOneUsesTheSameSlowdowns() {
    let r = record("a", fade: 25).result
    XCTAssertEqual(InsightPicker.pick(r).rule, 1)
    XCTAssertEqual(RunFade.slowdowns(r).count, 7)
  }

  func testHomeStates() {
    XCTAssertEqual(HomeModel(records: [], now: now).state, .none)
    XCTAssertEqual(HomeModel(records: [record("a", fade: 27)], now: now).state, .baseline)
    func trend(_ latest: Int) -> HomeState {
      HomeModel(records: [record("a", day: 0, fade: 27), record("b", day: 1, fade: latest)], now: now).state
    }
    XCTAssertEqual(trend(19), .trend(.down))
    XCTAssertEqual(trend(30), .trend(.steady))
    XCTAssertEqual(trend(24), .trend(.steady))
    XCTAssertEqual(trend(31), .trend(.up))
  }

  func testHeroCopyDiffersPerState() {
    func sig(_ m: HomeModel) -> String { [m.kicker, m.hero, m.line, m.chip ?? "-"].joined(separator: "|") }
    let models = [
      HomeModel(records: [], now: now),
      HomeModel(records: [record("a", fade: 27)], now: now),
      HomeModel(records: [record("a", day: 0, fade: 27), record("b", day: 1, fade: 19)], now: now),
      HomeModel(records: [record("a", day: 0, fade: 27), record("b", day: 1, fade: 28)], now: now),
      HomeModel(records: [record("a", day: 0, fade: 27), record("b", day: 1, fade: 31)], now: now),
    ]
    XCTAssertEqual(Set(models.map(sig)).count, models.count)
    XCTAssertEqual(models[2].chip, "8 s less fade since 24 Oct")
    XCTAssertEqual(models[4].chip, "4 s more than last time")
    XCTAssertEqual(models[3].chip, "Holding since 24 Oct")
  }

  func testNegativeFadeClampsToZero() {
    let m = HomeModel(records: [record("a", fade: -3)], now: now)
    XCTAssertEqual(m.latestFade, -3)
    XCTAssertEqual(m.hero, "0 s")
    XCTAssertEqual(m.line, "faster than run 1")
    XCTAssertEqual(m.recent, [0])
    XCTAssertEqual(HomeModel(records: [record("a", fade: 5)], now: now).line, "slower per run than run 1")
  }

  func testTrendUsesClampedFades() {
    let m = HomeModel(records: [record("a", day: 0, fade: -10), record("b", day: 1, fade: -2)], now: now)
    XCTAssertEqual(m.hero, "0 s")
    XCTAssertEqual(m.state, .trend(.steady))
    XCTAssertEqual(m.chip, "Holding since 24 Oct")
  }

  func testLegendOnlyWithMoreThanOneType() {
    let one = HomeModel(records: [record("a", day: 0, fade: 5), record("b", day: 1, fade: 6)], now: now)
    XCTAssertEqual(one.legendTypes, [.fullSim])
    let two = HomeModel(records: [record("a", .halfSim, day: 0, fade: 5), record("b", day: 1, fade: 6)], now: now)
    XCTAssertEqual(two.legendTypes, [.halfSim, .fullSim])
  }

  func testAlternatingHalfAndFullNeverCompareAcrossTypes() {
    // Half sims read structurally lower than full sims. Full 27, half 12, full 28, half 13: no false "less fade".
    let recs = [record("a", .fullSim, day: 0, fade: 27), record("b", .halfSim, day: 1, fade: 12),
                record("c", .fullSim, day: 2, fade: 28), record("d", .halfSim, day: 3, fade: 13)]
    let m = HomeModel(records: recs, now: now)
    XCTAssertEqual(m.heroType, .halfSim)
    XCTAssertEqual(m.hero, "13 s")
    XCTAssertEqual(m.previousFade, 12)
    XCTAssertEqual(m.state, .trend(.steady))
    XCTAssertEqual(m.kicker, "HALF SIM FADE")
    // The latest full sim (28) is compared with the earlier full sim (27), not with the half sim before it.
    let full = HomeModel(records: Array(recs.prefix(3)), now: now)
    XCTAssertEqual(full.heroType, .fullSim)
    XCTAssertEqual(full.previousFade, 27)
    XCTAssertEqual(full.state, .trend(.steady))
  }

  func testFirstOfATypeIsABaselineNotATrend() {
    let m = HomeModel(records: [record("a", .fullSim, day: 0, fade: 27), record("b", .halfSim, day: 1, fade: 12)], now: now)
    XCTAssertEqual(m.state, .baseline)
    XCTAssertEqual(m.kicker, "HALF SIM FADE \u{00B7} BASELINE")
    XCTAssertEqual(m.chip, "1 HALF SIM")
  }

  func testNoFalseLeastFadeAcrossTypes() {
    let full = record("a", .fullSim, day: 0, fade: 27)
    let half = record("b", .halfSim, day: 7, fade: 12)
    XCTAssertEqual(MomentPicker.pick(previous: [full], new: half), .first(.halfSim))
    // Within a type it still fires.
    let half2 = record("c", .halfSim, day: 14, fade: 5, total: 40)
    XCTAssertEqual(MomentPicker.pick(previous: [full, half], new: half2), .leastFade(previous: 12))
  }

  func testPartialsNeverBecomeTheHeroOrTheTrend() {
    let complete = record("a", .fullSim, day: 0, fade: 27)
    let partial = record("p", .fullSim, day: 1, fade: 2, until: 11)
    let m = HomeModel(records: [complete, partial], now: now)
    XCTAssertEqual(m.state, .baseline)
    XCTAssertEqual(m.hero, "27 s")
    XCTAssertEqual(HomeModel(records: [partial], now: now).state, .none)
  }

  func testRecentIsLastSixOldestFirst() {
    let recs = (0..<8).map { record("r\($0)", day: Int64($0), fade: 20 + $0) }
    XCTAssertEqual(HomeModel(records: recs, now: now).recent, [22, 23, 24, 25, 26, 27])
  }

  func testRecommendationRules() {
    XCTAssertEqual(Recommendation.pick(records: [], now: now).rule, 1)
    XCTAssertEqual(Recommendation.pick(records: [], now: now).type, .halfSim)
    // Last session full sim one day ago, fine wall balls: half sim.
    XCTAssertEqual(Recommendation.pick(records: [record("a", day: 1, fade: 5)], now: now).type, .halfSim)
    // Only a half sim: no full sim yet.
    XCTAssertEqual(Recommendation.pick(records: [record("a", .halfSim, day: 1, fade: 5)], now: now).type, .fullSim)
    // Full sim 12 days ago.
    XCTAssertEqual(Recommendation.pick(records: [record("a", day: -12, fade: 5)], now: now).rule, 3)
    // Wall balls the worst station.
    XCTAssertEqual(Recommendation.pick(records: [record("a", day: 1, fade: 5, wallBallsExtra: 80)], now: now).type, .wallBallFocus)
  }

  func testFullSimReturnsAfterAWallBallFocusSession() {
    // Focus session 1 s... +5 s over plan at wall balls, full sim 12 days ago: no loop, back to the full sim.
    let full = record("a", .fullSim, day: -12, fade: 5)
    let focus = record("f", .wallBallFocus, day: 0, fade: 5, wallBallsExtra: 5)
    let rec = Recommendation.pick(records: [full, focus], now: now)
    XCTAssertEqual(rec.type, .fullSim)
    XCTAssertEqual(rec.rule, 3)
    // Even a big wall-ball overrun in a focus session does not recommend focus again.
    let bigFocus = record("g", .wallBallFocus, day: 0, fade: 5, wallBallsExtra: 80)
    XCTAssertNotEqual(Recommendation.pick(records: [full, bigFocus], now: now).type, .wallBallFocus)
  }

  func testSmallWallBallOverrunDoesNotTriggerFocus() {
    let r = record("a", .fullSim, day: 1, fade: 5, wallBallsExtra: 5)
    XCTAssertEqual(Recommendation.pick(records: [r], now: now).type, .halfSim)
  }

  func testAbandonedFullSimDoesNotResetTheFullSimClock() {
    let old = record("a", .fullSim, day: -12, fade: 5)
    let partial = record("p", .fullSim, day: 1, fade: 5, until: 11)
    XCTAssertEqual(Recommendation.pick(records: [old, partial], now: now).rule, 3)
  }

  func testMomentPriority() {
    let a = record("a", .fullSim, day: 0, fade: 30, total: 10)
    // First of its type.
    XCTAssertEqual(MomentPicker.pick(previous: [], new: a), .first(.fullSim))
    // Faster total wins over least fade.
    let b = record("b", .fullSim, day: 7, fade: 10, total: 0)
    XCTAssertEqual(MomentPicker.pick(previous: [a], new: b), .best(.fullSim, previousBest: a.result.totalSeconds))
    // Slower but much lower fade.
    let c = record("c", .fullSim, day: 7, fade: 10, total: 20)
    XCTAssertEqual(MomentPicker.pick(previous: [a], new: c), .leastFade(previous: 30))
    // Neither.
    let d = record("d", .fullSim, day: 7, fade: 29, total: 20)
    XCTAssertNil(MomentPicker.pick(previous: [a], new: d))
    // A different type is a first.
    let h = record("h", .halfSim, day: 7, fade: 29)
    XCTAssertEqual(MomentPicker.pick(previous: [a], new: h), .first(.halfSim))
  }

  func testPartialSessionsGetNoMoment() {
    let a = record("a", .fullSim, day: 0, fade: 30, total: 10)
    let partial = record("p", .fullSim, day: 7, fade: 5, until: 11)
    XCTAssertNil(MomentPicker.pick(previous: [a], new: partial))
    XCTAssertNil(MomentPicker.pick(previous: [], new: partial))
  }

  func testFirstFiresOnceNotAgainAfterAPartial() {
    let partial = record("p", .fullSim, day: 0, fade: 5, until: 11)
    let complete = record("c", .fullSim, day: 7, fade: 30)
    // The partial earned nothing, so the first complete full sim is still the first.
    XCTAssertEqual(MomentPicker.pick(previous: [partial], new: complete), .first(.fullSim))
    let second = record("d", .fullSim, day: 14, fade: 29, total: 40)
    XCTAssertNil(MomentPicker.pick(previous: [partial, complete], new: second))
  }

  func testLeastFadeNeedsTheFullMargin() {
    let a = record("a", .fullSim, day: 0, fade: 30, total: 10)
    XCTAssertEqual(MomentPicker.pick(previous: [a], new: record("b", .fullSim, day: 7, fade: 27, total: 20)), .leastFade(previous: 30))
    XCTAssertNil(MomentPicker.pick(previous: [a], new: record("c", .fullSim, day: 7, fade: 28, total: 20)))
  }

  func testBackfilledSessionIsNotJudgedAgainstTheFuture() {
    let newer = record("n", .fullSim, day: 10, fade: 5)
    let old = record("o", .fullSim, day: 0, fade: 30)
    XCTAssertEqual(MomentPicker.pick(previous: [newer], new: old), .first(.fullSim))
  }
}
