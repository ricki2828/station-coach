import XCTest
@testable import CoachKit

final class ArrivalGateTests: XCTestCase {
  func testOpenGateRunsAtOnce() {
    let gate = ArrivalGate()
    var ran: [Int] = []
    gate.submit { ran.append(1) }
    XCTAssertEqual(ran, [1])
    XCTAssertEqual(gate.heldCount, 0)
  }

  func testClosedGateHoldsThenRunsInOrderOnOpen() {
    let gate = ArrivalGate()
    var ran: [Int] = []
    gate.close()
    gate.submit { ran.append(1) }
    gate.submit { ran.append(2) }
    XCTAssertEqual(ran, [], "nothing lands while the zip is being built")
    XCTAssertEqual(gate.heldCount, 2)
    gate.open()
    XCTAssertEqual(ran, [1, 2])
    XCTAssertFalse(gate.isClosed)
    gate.submit { ran.append(3) }
    XCTAssertEqual(ran, [1, 2, 3])
  }

  /// Work queued during a zip may itself submit more work after the gate reopens.
  func testWorkSubmittedWhileDrainingRunsImmediately() {
    let gate = ArrivalGate()
    var ran: [String] = []
    gate.close()
    gate.submit { ran.append("a"); gate.submit { ran.append("b") } }
    gate.open()
    XCTAssertEqual(ran, ["a", "b"])
  }
}
