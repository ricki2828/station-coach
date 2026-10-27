import CoachKit
import SwiftUI
import UIKit
import XCTest
@testable import CoachUI

/// Measures what is drawn, not what was asked for: the dominant number is rendered in a probe colour and its
/// ink is measured in the pixels. A number shrunk by a scale factor (or squeezed out) fails here.
@MainActor
final class LayoutTests: XCTestCase {
  private let scale: CGFloat = 3

  /// The measurements behind every assertion, written next to the PNGs as `layout-report.txt` so a failure in CI
  /// can be read without the truncated xcodebuild log.
  private static var report: [String] = []

  private func note(_ line: String) {
    Self.report.append(line)
    guard let dir = ProcessInfo.processInfo.environment["SCREENS_DIR"], !dir.isEmpty else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? Self.report.joined(separator: "\n").write(toFile: dir + "/layout-report.txt", atomically: true, encoding: .utf8)
  }

  /// Bounding box, in points, of pure-red pixels in a render of the screen inside the chrome of the given case size.
  private func probeBox(_ model: StepScreenModel, size: CGSize = Theme.watch46, dimmed: Bool = false) -> CGSize {
    let view = WatchChrome(size: size) { CoachStepScreen(model: model, onMissed: {}) }
      .environment(\.dominantProbe, Color(red: 1, green: 0, blue: 0))
      .environment(\.watchDimmed, dimmed)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.uiImage?.cgImage else { return .zero }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 4
        if px[i] > 235, px[i + 1] < 40, px[i + 2] < 40 {
          minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= 0 else { return .zero }
    return CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
  }

  private func model(_ kind: StepScreenModel.Kind, _ a: Activity, dominant: String, badge: String? = nil, hr: Int? = 142,
                     approximate: Bool = false) -> StepScreenModel {
    StepScreenModel(kind: kind, activity: a, title: kind == .reps ? "Wall balls" : "Run 4", badge: badge, dominant: dominant,
                    dominantLabel: "", secondary: "/ 5:24", secondaryLabel: "", next: "Next: Sled push", deltaSeconds: -20,
                    hrBpm: hr, approximate: approximate)
  }

  func testDominantDigitsAreDrawnAtFullSize() {
    let cases: [(String, StepScreenModel)] = [
      ("run", model(.run, .run, dominant: "3:12")),
      ("run, long time", model(.run, .run, dominant: "10:41")),
      ("transition", model(.run, .run, dominant: "0:12", badge: "Transition")),
      ("station", model(.time, .skierg, dominant: "2:10")),
      ("reps", model(.reps, .wallBalls, dominant: "100")),
      ("reps, approximate", model(.reps, .wallBalls, dominant: "97", approximate: true)),
    ]
    for (name, m) in cases {
      let box = probeBox(m)
      // Digit height of a 64 pt heavy face is about 0.7 em (45 pt); the 44 pt shrink the review measured gives about 31.
      XCTAssertGreaterThanOrEqual(box.height, 40, "\(name): dominant ink is \(box)")
      XCTAssertGreaterThan(box.width, 40, "\(name): dominant ink is \(box)")
    }
  }

  private var probeCases: [(String, StepScreenModel)] {
    [
      ("run", model(.run, .run, dominant: "3:12")),
      ("run, long time", model(.run, .run, dominant: "10:41")),
      ("transition", model(.run, .run, dominant: "0:12", badge: "Transition")),
      ("station", model(.time, .skierg, dominant: "2:10")),
      ("reps", model(.reps, .wallBalls, dominant: "100")),
      ("reps, approximate", model(.reps, .wallBalls, dominant: "97", approximate: true)),
    ]
  }

  func testDominantInkIsAtLeast40ptAtEverySize() {
    for size in WatchSizes.all {
      for (name, m) in probeCases {
        let box = probeBox(m, size: size.points)
        note("ink \(size.mm) mm \(name): \(box.width) x \(box.height)")
        XCTAssertGreaterThanOrEqual(box.height, 40, "\(size.mm) mm, \(name): dominant ink is \(box)")
        XCTAssertGreaterThan(box.width, 40, "\(size.mm) mm, \(name): dominant ink is \(box)")
        XCTAssertLessThanOrEqual(box.width, size.points.width - 2 * Theme.Space.watchEdge, "\(size.mm) mm, \(name): \(box)")
      }
    }
  }

  func testDimmedDominantKeepsItsInkAtEverySize() {
    for size in WatchSizes.all {
      for (name, m) in probeCases {
        let box = probeBox(m, size: size.points, dimmed: true)
        note("ink dimmed \(size.mm) mm \(name): \(box.width) x \(box.height)")
        XCTAssertGreaterThanOrEqual(box.height, 40, "\(size.mm) mm dimmed, \(name): dominant ink is \(box)")
      }
    }
  }

  func testDimClockDropsTheSeconds() {
    XCTAssertEqual(DimClock.parts("3:12").value, "3")
    XCTAssertEqual(DimClock.parts("3:12").unit, "min")
    XCTAssertEqual(DimClock.parts("10:41").value, "10")
    XCTAssertEqual(DimClock.parts("1:02:10").value, "1:02")
    XCTAssertNil(DimClock.parts("1:02:10").unit)
    XCTAssertEqual(DimClock.parts("45").value, "45")
  }

  // MARK: Nothing clips under the clock inset

  /// The natural height of a screen laid out at the given case size; it must fit under the clock inset or the bottom row clips.
  private func naturalHeight<V: View>(_ view: V, _ size: CGSize, dimmed: Bool = false) -> CGFloat {
    let host = UIHostingController(rootView: view
      .environment(\.watchCompact, size.height <= watchCompactMaxHeight)
      .environment(\.watchDimmed, dimmed)
      .fixedSize(horizontal: false, vertical: true))
    return host.sizeThatFits(in: CGSize(width: size.width, height: 10_000)).height
  }

  private func fits<V: View>(_ name: String, _ view: V, dimmed: Bool = false) {
    for size in WatchSizes.all {
      let budget = size.points.height - WatchChrome<EmptyView>.topInset
      let h = naturalHeight(view, size.points, dimmed: dimmed)
      note("height \(size.mm) mm (budget \(budget)) \(name): \(h)")
      XCTAssertLessThanOrEqual(h, budget, "\(name) at \(size.mm) mm is \(h) pt tall; \(budget) under the clock")
    }
  }

  private func ladder(_ n: Int) -> [LadderTick] { LadderTick.ladder(for: SampleData.plan, currentIndex: n) }

  func testStepScreensFitUnderTheClockAtEverySize() {
    var withLadder = model(.time, .skierg, dominant: "2:10")
    withLadder.ladder = ladder(7)
    var hrOff = model(.run, .run, dominant: "3:12", hr: nil)
    hrOff.hrOff = true
    var transition = model(.run, .run, dominant: "0:12", badge: "Transition")
    transition.next = "Next: Burpee broad jumps"
    var noRep = model(.reps, .wallBalls, dominant: "45")
    noRep.noRepVisible = true
    noRep.noRepCount = 2
    noRep.next = ""
    var toast = model(.run, .run, dominant: "3:12")
    toast.toast = "Headphones lost, vibrating instead"
    var alarm = model(.run, .run, dominant: "3:12")
    alarm.alarm = "Workout session ended"
    var changeover = model(.run, .run, dominant: "10:41", badge: "Changeover", hr: 171)
    changeover.deltaSeconds = 641
    changeover.ladder = ladder(6)
    let cases: [(String, StepScreenModel)] = [
      ("toast", toast), ("alarm", alarm), ("changeover", changeover),
      ("run", model(.run, .run, dominant: "3:12")), ("station", model(.time, .skierg, dominant: "2:10")),
      ("long next", transition), ("hr off", hrOff), ("ladder", withLadder),
      ("reps", model(.reps, .wallBalls, dominant: "100")), ("reps no rep", noRep),
    ]
    for (name, m) in cases {
      fits(name, CoachStepScreen(model: m, onMissed: {}))
      fits("\(name), dimmed", CoachStepScreen(model: m, onMissed: {}), dimmed: true)
    }
  }

  func testFinishReadyAndMenuFitUnderTheClockAtEverySize() {
    let all = FinishScreenModel.stations(from: SampleData.result(extra: [1: -25, 5: 41]))
    let early = FinishScreenModel.stations(from: SampleData.result(until: 10))
    let finishes: [(String, FinishScreenModel)] = [
      ("finish under", FinishScreenModel(mode: .saved, totalText: "1:18:42", line: "1:18 under target", early: false, best: "Row \u{2212}0:25",
                                         worst: "Sled pull +0:41", totalSeconds: 4722, stations: all)),
      ("finish undo", FinishScreenModel(mode: .saved, totalText: "1:18:42", line: "1:18 under target", early: false, undoSecondsLeft: 8,
                                        totalSeconds: 4722, stations: all)),
      ("finish early", FinishScreenModel(mode: .saved, totalText: "52:10", line: "Ended at Row. 5 of 8 stations.", early: true,
                                         totalSeconds: 3130, stations: early)),
      ("finish save failed", FinishScreenModel(mode: .saveFailed(missing: 1), totalText: "1:18:42", line: "1:18 under target", early: false,
                                               totalSeconds: 4722, stations: all)),
    ]
    for (name, m) in finishes { fits(name, CoachFinishScreen(model: m, animate: false)) }
    let ready = ReadyInfo(sessionName: "Full sim", targetText: "1:20:00")
    let warned = ReadyInfo(sessionName: "Full sim", targetText: "1:20:00",
                           chips: ["No headphones: cues by vibration", "Heart rate off. The coach still works."],
                           batteryLine: "Battery 54%. A full sim needs about 60%.")
    fits("ready", CoachReadyScreen(model: .ready(ready)))
    fits("ready warnings", CoachReadyScreen(model: .ready(warned)))
    fits("ready no plan", CoachReadyScreen(model: .noPlan))
    fits("menu", CoachMenuScreen())
  }

  func testReadyWarningsAreOneShortLine() {
    let info = ReadyInfo(sessionName: "Full sim", targetText: "1:20:00",
                         chips: ["No headphones: cues by vibration", "Heart rate off. The coach still works."],
                         batteryLine: "Battery 54%. A full sim needs about 60%.")
    XCTAssertEqual(CoachReadyScreen.warningLine(info)?.short, "No headphones \u{00B7} Heart rate off \u{00B7} Battery 54%")
    XCTAssertNil(CoachReadyScreen.warningLine(ReadyInfo(sessionName: "Full sim", targetText: "1:20:00")))
  }

  func testDimmedDeltaDropsItsSeconds() {
    XCTAssertEqual(DeltaBand(seconds: 32, dimmed: true).bandText, "+1 min")
    XCTAssertEqual(DeltaBand(seconds: -20, dimmed: true).bandText, "\u{2212}0 min".replacingOccurrences(of: "\u{2212}0", with: "0"))
    XCTAssertEqual(DeltaBand(seconds: -125, dimmed: true).bandText, "\u{2212}2 min")
    XCTAssertEqual(DeltaBand(seconds: 32).bandText, "+0:32")
  }

  func testNextLineShowsOnRegularStationScreensOnly() {
    let m = model(.time, .skierg, dominant: "2:10")
    let compact = naturalHeight(CoachStepScreen(model: m, onMissed: {}), WatchSizes.all[0].points)
    var noNext = m
    noNext.next = ""
    XCTAssertEqual(compact, naturalHeight(CoachStepScreen(model: noNext, onMissed: {}), WatchSizes.all[0].points), accuracy: 0.5,
                   "the compact step screen must not gain a row")
    let regular = WatchSizes.all[4].points
    XCTAssertGreaterThan(naturalHeight(CoachStepScreen(model: m, onMissed: {}), regular),
                         naturalHeight(CoachStepScreen(model: noNext, onMissed: {}), regular) + 15)
  }

  func testLadderHasOneTickPerStepAndMarksProgress() {
    let ticks = ladder(5)
    XCTAssertEqual(ticks.count, SampleData.plan.steps.count)
    XCTAssertEqual(ticks.filter { $0.state == .done }.count, 5)
    XCTAssertEqual(ticks.filter { $0.state == .current }.count, 1)
    XCTAssertNil(model(.run, .run, dominant: "1:00").ladder, "the ladder is off until the coach fills it")
  }

  func testRepsNumberFitsBetweenTheButtons() {
    let box = probeBox(model(.reps, .wallBalls, dominant: "100"))
    XCTAssertGreaterThan(box.width, 0)
    XCTAssertLessThanOrEqual(box.width, Theme.watch46.width - 2 * Theme.Space.watchEdge - 88)
  }

  func testApproximateRepsKeepTheirRoomBesideTheButtons() {
    // The "~" is a badge in the title row now, so the widest count still fits with both buttons.
    for text in ["100", "97", "45"] {
      let box = probeBox(model(.reps, .wallBalls, dominant: text, approximate: true))
      XCTAssertGreaterThanOrEqual(box.height, 40, text)
      XCTAssertLessThanOrEqual(box.width, Theme.watch46.width - 2 * Theme.Space.watchEdge - 88 - 8, "\(text): \(box)")
    }
  }

  func testDominantIsTheTallestInkOnTheScreen() {
    // The delta band and secondary number must not out-shout the step's own number.
    XCTAssertGreaterThan(Theme.Size.dominant, Theme.Size.secondary)
    XCTAssertGreaterThan(Theme.Size.secondary, Theme.Size.band)
  }
}
