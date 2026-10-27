#if os(iOS)
import AVFoundation
import CoachKit
import SwiftUI
import UIKit

/// Renders `ShareLoopFrame` at 30 fps and encodes H.264 into an mp4, on the device. No server, no network.
/// The still card holds for over a second, so those frames are rendered once and reused.
@MainActor
public enum ShareLoopEncoder {
  public struct Report: Equatable {
    public let url: URL
    public let frames: Int
    public let rendered: Int
    public let seconds: Double
  }

  public enum EncodeError: Error { case writer(String), render(Int), cancelled }

  /// Writes the loop to `url` (replacing a file there). `progress` gets 0...100 after each frame. Cancelling the task stops it
  /// and removes the partial file. Throws on any failure; the caller falls back to the still card.
  public static func encode(result: CoachResult, moment: MomentDisplay? = nil, dateText: String? = nil, to url: URL,
                            progress: @escaping (Int) -> Void = { _ in }) async throws -> Report {
    let started = Date()
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let w = Int(ShareLoop.pixelSize.width), h = Int(ShareLoop.pixelSize.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: w, AVVideoHeightKey: h,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
    ])
    guard writer.canAdd(input) else { throw EncodeError.writer("cannot add input") }
    writer.add(input)
    guard writer.startWriting() else { throw EncodeError.writer(writer.error?.localizedDescription ?? "start failed") }
    writer.startSession(atSourceTime: .zero)

    func fail(_ e: Error) -> Error {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      return e
    }

    var still: CVPixelBuffer?
    var rendered = 0
    let n = ShareLoop.frameCount
    for i in 0..<n {
      if Task.isCancelled { throw fail(EncodeError.cancelled) }
      let t = Double(i) / Double(ShareLoop.fps)
      let buffer: CVPixelBuffer
      if ShareLoop.isStill(t), let s = still {
        buffer = s
      } else {
        guard let b = pixelBuffer(of: ShareLoopFrame(result: result, moment: moment, dateText: dateText, t: t), width: w, height: h) else {
          throw fail(EncodeError.render(i))
        }
        rendered += 1
        buffer = b
        if ShareLoop.isStill(t) { still = b }
      }
      while !input.isReadyForMoreMediaData {
        if Task.isCancelled { throw fail(EncodeError.cancelled) }
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(ShareLoop.fps))) else {
        throw fail(EncodeError.writer(writer.error?.localizedDescription ?? "append failed"))
      }
      progress(Int(Double(i + 1) / Double(n) * 100))
      await Task.yield() // let the progress bar and Cancel run
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw fail(EncodeError.writer(writer.error?.localizedDescription ?? "finish failed")) }
    return Report(url: url, frames: n, rendered: rendered, seconds: Date().timeIntervalSince(started))
  }

  /// One frame as a 32BGRA pixel buffer at exactly `width` x `height` (360 x 450 pt at scale 3).
  static func pixelBuffer(of view: some View, width: Int, height: Int) -> CVPixelBuffer? {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = ShareCardV2.renderScale
    guard let cg = renderer.uiImage?.cgImage else { return nil }
    var out: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &out)
    guard let buffer = out else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
#endif
