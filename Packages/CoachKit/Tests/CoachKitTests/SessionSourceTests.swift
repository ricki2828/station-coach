import XCTest
@testable import CoachKit

final class SessionSourceTests: XCTestCase {
  private final class Fake: SessionSource {
    let kind = SessionSourceKind.watchConnectivity
    var isReady = true
    var delivered: [SessionPlan] = []
    func deliver(plan: SessionPlan) -> PlanDelivery {
      delivered.append(plan)
      return isReady ? .sent : .appMissing
    }
  }

  func testDecideChecksInTheOldOrder() {
    XCTAssertEqual(PlanDelivery.decide(supported: false, activated: false, paired: false, appInstalled: false), .unsupported)
    XCTAssertEqual(PlanDelivery.decide(supported: true, activated: false, paired: true, appInstalled: true), .notActivated)
    XCTAssertEqual(PlanDelivery.decide(supported: true, activated: true, paired: false, appInstalled: true), .appMissing)
    XCTAssertEqual(PlanDelivery.decide(supported: true, activated: true, paired: true, appInstalled: false), .appMissing)
    XCTAssertNil(PlanDelivery.decide(supported: true, activated: true, paired: true, appInstalled: true))
  }

  func testPlanContextIsTheJSONTextUnderPlan() throws {
    let plan = PlanBuilder.build(division: .openMen, target: 90 * 60, type: .fullSim)
    let context = try SessionSourceCodec.planContext(plan)
    XCTAssertEqual(Array(context.keys), ["plan"])
    let text = try XCTUnwrap(context["plan"] as? String)
    XCTAssertEqual(try JSONDecoder().decode(SessionPlan.self, from: Data(text.utf8)), plan)
  }

  func testAnySourceCanStandInForTheWatch() {
    let fake = Fake()
    let source: SessionSource = fake
    let plan = PlanBuilder.build(division: .proWomen, target: 80 * 60, type: .halfSim)
    XCTAssertEqual(source.deliver(plan: plan), .sent)
    fake.isReady = false
    XCTAssertEqual(source.deliver(plan: plan), .appMissing)
    XCTAssertEqual(fake.delivered.count, 2)
  }
}
