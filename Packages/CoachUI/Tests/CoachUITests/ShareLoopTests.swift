import AVFoundation
import CoachKit
import SwiftUI
import UIKit
import XCTest
@testable import CoachUI

/// Key frames of the share loop as PNGs (CI `screens` artifact), the still-card equality, and an on-simulator encode.
@MainActor
final class ShareLoopTests: XCTestCase {
  private var outDir: URL {
    if let p = ProcessInfo.processInfo.environment["SCREENS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("screens", isDirectory: true)
  }

  private let full = SampleData.result(extra: [4: 45, 5: 41, 13: 18])
  private let partial = SampleData.result(extra: [4: 30], until: 10)
  private let best = MomentDisplay.make(.best(.fullSim, previousBest: 4864), totalSeconds: 4702, fadeSeconds: nil, previousDate: "24 Oct")
  private let date = "Sat 24 Oct"

  private func image(_ view: some View, scale: CGFloat = ShareCardV2.renderScale) throws -> UIImage {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
    r.scale = scale
    return try XCTUnwrap(r.uiImage)
  }

  private func write(_ img: UIImage, _ name: String) throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let png = try XCTUnwrap(img.pngData())
    XCTAssertGreaterThan(png.count, 3_000, name)
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
  }

  private func frame(_ result: CoachResult, _ moment: MomentDisplay? = nil, t: Double) -> ShareLoopFrame {
    ShareLoopFrame(result: result, moment: moment, dateText: date, t: t)
  }

  /// Mean absolute difference per colour channel (0...255) between two images of the same size.
  private func meanDiff(_ a: UIImage, _ b: UIImage) throws -> Double {
    func bytes(_ i: UIImage) throws -> [UInt8] {
      let cg = try XCTUnwrap(i.cgImage)
      var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
      let ctx = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      return data
    }
    let x = try bytes(a), y = try bytes(b)
    XCTAssertEqual(x.count, y.count)
    var sum = 0
    for i in 0..<min(x.count, y.count) { sum += abs(Int(x[i]) - Int(y[i])) }
    return Double(sum) / Double(max(1, min(x.count, y.count)))
  }

  func testKeyFrames() throws {
    let frames: [(String, CoachResult, MomentDisplay?, Double)] = [
      ("full", full, nil, 0.4), ("full", full, nil, 1.5), ("full", full, nil, 2.7), ("full", full, nil, 3.5), ("full", full, nil, 4.5),
      ("partial", partial, nil, 1.5), ("partial", partial, nil, 4.5),
      ("best", full, best, 3.0),
      // A full sim is past the hour, so its count-up shows H:MM:SS from frame 0 with no width jump.
      ("hour", full, nil, 1.5),
    ]
    for (name, result, moment, t) in frames {
      let img = try image(frame(result, moment, t: t))
      XCTAssertEqual(img.size.width * img.scale, 1080)
      XCTAssertEqual(img.size.height * img.scale, 1350)
      try write(img, "phone-shareloop-\(name)-t\(t)")
    }
  }

  func testShareFlowScreens() throws {
    func sheet(_ s: ShareFlowState, partial: Bool = false) -> some View {
      ShareFlowSheet(state: s, partial: partial).frame(width: Theme.phone.width, height: 360)
    }
    try write(image(sheet(.choosing), scale: 2), "phone-share-sheet")
    try write(image(sheet(.choosing, partial: true), scale: 2), "phone-share-sheet-partial")
    try write(image(sheet(.rendering(percent: 40)), scale: 2), "phone-share-rendering")
    try write(image(sheet(.failed), scale: 2), "phone-share-failed")
  }

  /// The hold frames are the still card itself, so the video ends on the image people already share.
  func testHoldFramesAreTheStillCard() throws {
    let still = try image(ShareCardV2(result: full, dateText: date))
    XCTAssertEqual(try meanDiff(image(frame(full, t: 4.5)), still), 0, accuracy: 0.01)
    XCTAssertEqual(try meanDiff(image(frame(full, best, t: 3.8)), image(ShareCardV2(result: full, dateText: date, moment: best))), 0, accuracy: 0.01)
  }

  /// The last animated frame has settled into the still: a change to the card's copy or layout that the loop does not copy fails here.
  func testLastAnimatedFrameMatchesTheStill() throws {
    for (result, moment) in [(full, nil), (partial, nil), (full, best)] as [(CoachResult, MomentDisplay?)] {
      let still = try image(ShareCardV2(result: result, dateText: date, moment: moment))
      let d = try meanDiff(image(frame(result, moment, t: 3.79)), still)
      XCTAssertLessThan(d, 0.5, "last animated frame drifts from the still card (mean diff \(d))")
    }
  }

  func testCountUpDoesNotChangeWidthPastAnHour() {
    XCTAssertEqual(ShareLoop.clock(0, hour: true), "0:00:00")
    XCTAssertEqual(ShareLoop.clock(3599, hour: true), "0:59:59")
    XCTAssertEqual(ShareLoop.clock(4904, hour: true), "1:21:44")
    XCTAssertEqual(ShareLoop.clock(125, hour: false), "2:05")
    XCTAssertEqual(ShareLoop.frameCount, 150)
  }

  /// The composited frame (layers drawn with an alpha or an offset) matches the reference render of the same view at the same `t`.
  func testCompositedFramesMatchTheFullRender() throws {
    let cases: [(String, CoachResult, MomentDisplay?)] = [("full", full, nil), ("partial", partial, nil), ("best", full, best)]
    for (name, result, moment) in cases {
      let comp = ShareLoopCompositor(result: result, moment: moment, dateText: date)
      for t in [0.1, 0.3, 0.6, 0.85, 1.0, 1.4, 2.0, 2.6, 2.8, 3.0, 3.3, 3.6, 3.75, 4.9, 4.95] {
        if comp.needsFullRender(t) { continue }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1080, height: 1350, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        if ShareLoop.isStill(t) { comp.drawStill(into: ctx, alpha: 1) }
        else if t > ShareLoop.holdEnd { comp.drawStill(into: ctx, alpha: 1 - ShareLoop.progress(t, ShareLoop.holdEnd, ShareLoop.duration)) }
        else { comp.draw(t, into: ctx) }
        let composed = UIImage(cgImage: try XCTUnwrap(ctx.makeImage()))
        let d = try meanDiff(composed, image(frame(result, moment, t: t)))
        if d >= 1.5 {
          try write(composed, "fail-composite-\(name)-t\(t)")
          try write(image(frame(result, moment, t: t)), "fail-reference-\(name)-t\(t)")
        }
        XCTAssertLessThan(d, 1.5, "\(name) t=\(t): composite drifts from the full render (mean diff \(d))")
      }
    }
  }

  func testLiftNamesTheInsightsStation() throws {
    // Slow run after the sled push (rule 1): the run segment lifts. A slow station (rule 2): the station lifts.
    XCTAssertEqual(InsightPicker.pick(full).stepIndex, ShareLoop.liftIndex(full))
    XCTAssertNotNil(ShareLoop.liftIndex(full))
    XCTAssertNil(ShareLoop.liftIndex(partial), "a partial card writes its own insight, so nothing lifts")
  }

  func testEncodeWritesAnExactFiveSecondMp4AndTimesBothPaths() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var seen: [Int] = []
    let report = try await ShareLoopEncoder.encode(result: full, dateText: date, to: url) { seen.append($0) }

    // The reference path, for the timing comparison only.
    let whole = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-whole-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: whole) }
    let reference = try await ShareLoopEncoder.encode(result: full, dateText: date, to: whole, composite: false)
    let msg = String(format: "share loop encode, 150 frames on the CI simulator: composited %.2f s (%d ImageRenderer passes) vs every frame rendered whole %.2f s (%d passes); target 3 s on device",
                     report.seconds, report.renders, reference.seconds, reference.renders)
    print(msg)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try msg.write(to: outDir.appendingPathComponent("shareloop-encode-time.txt"), atomically: true, encoding: .utf8)

    let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
    XCTAssertGreaterThan(size, 10_000)
    XCTAssertLessThan(size, 3_000_000, "file over the 3 MB target: \(size)")
    XCTAssertEqual(seen.last, 100)
    XCTAssertLessThan(report.renders, reference.renders, "compositing should render less than the whole-frame path")
    XCTAssertLessThan(report.seconds, 600, "encode hung")

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    XCTAssertEqual(duration, 5.0, accuracy: 0.01, "the loop is exactly 5 s")
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let natural = try await track.load(.naturalSize)
    XCTAssertEqual(natural.width, 1080)
    XCTAssertEqual(natural.height, 1350)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    XCTAssertTrue(reader.startReading())
    var frames = 0
    while out.copyNextSampleBuffer() != nil { frames += 1 }
    XCTAssertEqual(frames, 150)

    // A decoded frame from the file is the still card, the right way up (a flipped or mis-coloured encode would be far off).
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let decoded = try await generator.image(at: CMTime(seconds: 4.5, preferredTimescale: 600)).image
    let still = try image(ShareCardV2(result: full, dateText: date))
    let d = try meanDiff(UIImage(cgImage: decoded), still)
    try write(UIImage(cgImage: decoded), "phone-shareloop-decoded-t4.5")
    XCTAssertLessThan(d, 8, "decoded t=4.5 frame differs from the still card (mean diff \(d))")
  }

  /// Cancelling part-way, wherever the loop happens to be (rendering, or waiting for the writer), cancels the writer and
  /// removes the partial file.
  func testCancellingMidEncodeLeavesNoFile() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-cancel-\(UUID().uuidString).mp4")
    var task: Task<ShareLoopEncoder.Report, Error>?
    var cancelled = false
    task = Task { @MainActor in
      try await ShareLoopEncoder.encode(result: full, dateText: date, to: url) { pct in
        if pct >= 10 && !cancelled { cancelled = true; task?.cancel() }
      }
    }
    do { _ = try await XCTUnwrap(task).value; XCTFail("a cancelled encode should throw") } catch ShareLoopEncoder.EncodeError.cancelled {} catch { XCTFail("wrong error \(error)") }
    XCTAssertTrue(cancelled, "cancel should have fired mid-encode")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testCancelBeforeTheFirstFrameLeavesNoFile() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-cancel0-\(UUID().uuidString).mp4")
    let task = Task { @MainActor in try await ShareLoopEncoder.encode(result: full, dateText: date, to: url) }
    task.cancel()
    do { _ = try await task.value; XCTFail("a cancelled encode should throw") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }
}
