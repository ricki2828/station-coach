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

  func testEncodeWritesAFiveSecondMp4() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var seen: [Int] = []
    let report = try await ShareLoopEncoder.encode(result: full, dateText: date, to: url) { seen.append($0) }
    let msg = String(format: "share loop encode: %.2f s for %d frames (%d rendered), target 3 s on device", report.seconds, report.frames, report.rendered)
    print(msg)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try msg.write(to: outDir.appendingPathComponent("shareloop-encode-time.txt"), atomically: true, encoding: .utf8)

    let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
    XCTAssertGreaterThan(size, 10_000)
    XCTAssertLessThan(size, 3_000_000, "file over the 3 MB target: \(size)")
    XCTAssertEqual(seen.last, 100)
    XCTAssertLessThan(report.rendered, report.frames, "the still frames are rendered once and reused")

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    XCTAssertEqual(duration, 5.0, accuracy: 0.1)
    let track = try XCTUnwrap(try await asset.loadTracks(withMediaType: .video).first)
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
    XCTAssertLessThan(report.seconds, 60, "encode should be nowhere near a minute even on a slow runner")
  }

  func testCancelledEncodeLeavesNoFile() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareloop-cancel-\(UUID().uuidString).mp4")
    let task = Task { @MainActor in try await ShareLoopEncoder.encode(result: full, dateText: date, to: url) }
    task.cancel()
    do { _ = try await task.value; XCTFail("a cancelled encode should throw") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }
}
