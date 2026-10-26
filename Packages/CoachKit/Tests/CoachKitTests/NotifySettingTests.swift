import XCTest
@testable import CoachKit

final class NotifySettingTests: XCTestCase {
  private func s(_ c: NotifyChoice, _ a: NotifyAuthorization) -> NotifySettingState { NotifySettingState(choice: c, auth: a) }

  func testSchedulesOnlyWhenWantedAndAllowed() {
    XCTAssertTrue(s(.yes, .authorized).isScheduling)
    for c in [NotifyChoice.undecided, .no] { XCTAssertFalse(s(c, .authorized).isScheduling) }
    for a in [NotifyAuthorization.notDetermined, .denied] { XCTAssertFalse(s(.yes, a).isScheduling) }
  }

  func testYesThenDecliningThePromptIsNotAPermanentNo() {
    let tapped = s(.undecided, .notDetermined).turnedOn()
    XCTAssertEqual(tapped.action, .askSystem)
    XCTAssertEqual(tapped.state.choice, .yes)
    let refused = tapped.state.afterPrompt(granted: false)
    XCTAssertEqual(refused.choice, .yes)
    XCTAssertFalse(refused.isScheduling)
    XCTAssertTrue(refused.blockedBySystem)
    XCTAssertFalse(refused.showsOptInCard)
    // Later: notifications enabled in iOS Settings, re-read on foreground. Scheduling starts again with no new tap.
    let enabled = NotifySettingState(choice: refused.choice, auth: .authorized)
    XCTAssertTrue(enabled.isScheduling)
    XCTAssertFalse(enabled.blockedBySystem)
  }

  func testGrantedPromptSchedules() {
    XCTAssertTrue(s(.undecided, .notDetermined).turnedOn().state.afterPrompt(granted: true).isScheduling)
  }

  func testSwitchTurnsOnPerWhatIosAllows() {
    XCTAssertEqual(s(.no, .authorized).turnedOn().action, .nothing)
    XCTAssertTrue(s(.no, .authorized).turnedOn().state.isScheduling)
    XCTAssertEqual(s(.no, .denied).turnedOn().action, .openSystemSettings)
    XCTAssertEqual(s(.no, .notDetermined).turnedOn().action, .askSystem)
  }

  func testSwitchOffIsTheAthletesAnswerAndCanBeUndone() {
    let off = s(.yes, .authorized).turnedOff()
    XCTAssertEqual(off.choice, .no)
    XCTAssertFalse(off.isScheduling)
    XCTAssertTrue(off.turnedOn().state.isScheduling)
  }

  func testOptInCardOnlyBeforeAnAnswerAndNotAfterIosSaidNo() {
    XCTAssertTrue(s(.undecided, .notDetermined).showsOptInCard)
    XCTAssertTrue(s(.undecided, .authorized).showsOptInCard)
    XCTAssertFalse(s(.undecided, .denied).showsOptInCard)
    XCTAssertFalse(s(.no, .notDetermined).showsOptInCard)
    XCTAssertFalse(s(.yes, .authorized).showsOptInCard)
    XCTAssertEqual(s(.undecided, .notDetermined).declinedCard().choice, .no)
  }
}
