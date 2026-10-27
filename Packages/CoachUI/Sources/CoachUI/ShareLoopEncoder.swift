#if os(iOS)
import AVFoundation
import CoachKit
import SwiftUI
import UIKit

/// Builds each loop frame from layers rendered once: the pieces that only fade or move are drawn as images with an alpha or an
/// offset (a CGContext draw is about a millisecond), so SwiftUI renders only what actually changes. The frames stay pure functions
/// of `t`: `ShareLoopFrame` is the reference, and ShareLoopTests checks the composite against it.
@MainActor
final class ShareLoopCompositor {
  private enum Key: Hashable {
    case layer(ShareLoopLayer), text(String), labels(Int), still
  }

  let result: CoachResult
  let moment: MomentDisplay?
  let dateText: String
  /// Passes through SwiftUI's `ImageRenderer` so far.
  private(set) var renders = 0
  private var cache: [Key: CGImage] = [:]
  /// Where each labelled station's segment ends, as a fraction of the strip's width, ascending and de-duplicated.
  private let labelEnds: [Double]
  private let size = CGSize(width: 1080, height: 1350)
  /// The band of the frame, in points from the top, that the count-up number is rendered in. The number sits between about 125 and 215.
  private static let textBandTop: CGFloat = 100
  private static let textBandHeight: CGFloat = 140
  /// Test hook: skip the station labels, to show the composite guard catches a dropped label.
  var debugDropLabels = false
  private let scale = ShareCardV2.renderScale
  /// The strip's left edge and width in pixels (20 pt page padding, 320 pt wide).
  private let stripX: CGFloat = 60
  private let stripW: CGFloat = 960

  init(result: CoachResult, moment: MomentDisplay?, dateText: String) {
    self.result = result
    self.moment = moment
    self.dateText = dateText
    let ends = ShareStrip.segmentEnds(result, width: 320)
    var out: [Double] = []
    for (i, row) in result.rows.enumerated() where !row.step.isRun {
      let e = ends[i]
      if !out.contains(where: { abs($0 - e) < 1e-9 }) { out.append(e) }
    }
    self.labelEnds = out.sorted()
  }

  private func render(_ view: some View) -> CGImage? {
    renders += 1
    let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
    r.scale = scale
    return r.uiImage?.cgImage
  }

  private func image(_ key: Key) -> CGImage? {
    if let c = cache[key] { return c }
    let img: CGImage?
    switch key {
    case .layer(let l):
      img = render(ShareLoopFrame(layer: l, result: result, moment: moment, dateText: dateText,
                                  heroText: l == .cardZero ? ShareLoop.heroText(result: result, moment: moment, clock: 0) : nil))
    case .text(let s):
      // The number sits in a band of the card; render only that band (a third of the canvas) and draw it back at its place.
      img = render(ShareLoopFrame(layer: .heroText, result: result, moment: moment, dateText: dateText, heroText: s)
        .offset(y: -Self.textBandTop)
        .frame(width: ShareCardV2.size.width, height: Self.textBandHeight, alignment: .topLeading)
        .clipped())
    case .labels(let k):
      img = render(ShareLoopFrame(layer: .labels, result: result, moment: moment, dateText: dateText, labelsRevealed: k < 0 ? 0 : labelEnds[k]))
    case .still:
      img = render(ShareCardV2(result: result, dateText: dateText, moment: moment))
    }
    // Count-up numbers are used once; keeping them all would hold dozens of 5.8 MB images.
    if let img { if case .text = key { cache = cache.filter { if case .text = $0.key { return false } else { return true } } }; cache[key] = img }
    return img
  }

  /// True when the frame cannot be composited (the badge's scale pop), so the caller renders it whole.
  func needsFullRender(_ t: Double) -> Bool { moment?.badge != nil && t >= 2.7 && t < 2.95 }

  func fullFrame(_ t: Double) -> CGImage? {
    render(ShareLoopFrame(result: result, moment: moment, dateText: dateText, t: t))
  }

  private func paint(_ ctx: CGContext, _ key: Key, alpha: Double = 1, dy: Double = 0, clipWidth: CGFloat? = nil) {
    guard alpha > 0.0005, let img = image(key) else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    if let clipWidth { ctx.clip(to: CGRect(x: stripX, y: 0, width: clipWidth, height: size.height)) }
    // Bitmap context space is y-up; SwiftUI offsets are y-down in points.
    // A cropped layer (the number's band) hangs from `top` points below the top edge; a full layer is at 0.
    let top: CGFloat = { if case .text = key { return Self.textBandTop * scale } else { return 0 } }()
    let h = CGFloat(img.height)
    ctx.draw(img, in: CGRect(x: 0, y: size.height - top - h - CGFloat(dy) * scale, width: size.width, height: h))
    ctx.restoreGState()
  }

  /// Draws frame `t` (not a hold frame) into a context over a 1080 x 1350 buffer.
  func draw(_ t: Double, into ctx: CGContext) {
    let st = ShareLoop.State.at(t)
    ctx.setFillColor(CGColor(srgbRed: 0xF8 / 255.0, green: 0xF6 / 255.0, blue: 0xF1 / 255.0, alpha: 1)) // PhoneTheme.paperHex
    ctx.fill(CGRect(origin: .zero, size: size))
    paint(ctx, .layer(.wordmark), alpha: st.wordmark)
    // Strip pieces fade in with the card's rise.
    paint(ctx, .layer(.track), alpha: st.rise * (1 - st.clock))
    paint(ctx, .layer(.bars), alpha: st.rise, clipWidth: stripW * CGFloat(st.clock))
    let done = labelEnds.lastIndex { $0 <= st.clock + 1e-9 }
    if let done, !debugDropLabels { paint(ctx, .labels(done), alpha: st.rise) }
    if st.lift > 0 && st.lift < 1 && ShareLoop.liftIndex(result) != nil {
      paint(ctx, .layer(.lift), dy: -6 * sin(Double.pi * st.lift))
    }
    // The hero card. During the rise the number is part of the group, so the alpha applies to both as the full render does.
    let cardDy = 60 * (1 - st.rise)
    if t < 0.9 {
      paint(ctx, .layer(.cardZero), alpha: st.rise, dy: cardDy)
    } else {
      paint(ctx, .layer(.cardBase))
      let hero = ShareLoop.heroText(result: result, moment: moment, clock: st.clock)
      let heroAlpha = moment?.heroSeconds == nil && moment != nil ? ShareLoop.progress(t, 0.9, 1.3) : 1
      paint(ctx, .text(hero), alpha: heroAlpha)
      if moment?.badge != nil, st.pop > 0 { paint(ctx, .layer(.badge)) }
      paint(ctx, .layer(.heroLine), alpha: st.line, dy: 12 * (1 - st.line))
    }
    paint(ctx, .layer(.insight), alpha: st.insight)
  }

  /// The still card as an image, for the hold and the fade to paper.
  func stillImage() -> CGImage? { image(.still) }

  /// Draws the still card over paper at `alpha` (the last 0.15 s fades the card out).
  func drawStill(into ctx: CGContext, alpha: Double) {
    ctx.setFillColor(CGColor(srgbRed: 0xF8 / 255.0, green: 0xF6 / 255.0, blue: 0xF1 / 255.0, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    paint(ctx, .still, alpha: alpha)
  }
}

/// Renders the share loop at 30 fps and encodes H.264 into an mp4, on the device. No server, no network.
/// The still card holds for over a second, so those frames are built once and reused.
@MainActor
public enum ShareLoopEncoder {
  public struct Report: Equatable {
    public let url: URL
    public let frames: Int
    /// Passes through SwiftUI's `ImageRenderer` (every layer, text image and whole frame counts).
    public let renders: Int
    public let seconds: Double
  }

  public enum EncodeError: Error { case writer(String), render(Int), cancelled }

  /// Writes the loop to `url` (replacing a file there). `progress` gets 0...100 after each frame. Cancelling the task, at any
  /// point, cancels the writer and removes the partial file. Throws on any failure; the caller falls back to the still card.
  /// `composite` false renders every frame whole (the reference path, used to time the compositor against).
  public static func encode(result: CoachResult, moment: MomentDisplay? = nil, dateText: String? = nil, to url: URL, composite: Bool = true,
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
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
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

    let date = dateText ?? ShareCardV2.date(result.startedAtEpochMs)
    let compositor = ShareLoopCompositor(result: result, moment: moment, dateText: date)
    let n = ShareLoop.frameCount
    var still: CVPixelBuffer?

    do {
      for i in 0..<n {
        try Task.checkCancellation()
        let t = Double(i) / Double(ShareLoop.fps)
        let buffer: CVPixelBuffer
        if ShareLoop.isStill(t), let s = still {
          buffer = s
        } else {
          guard let b = autoreleasepool(invoking: { () -> CVPixelBuffer? in
            guard let b = makeBuffer(adaptor, w, h) else { return nil }
            let ok = fill(b, w, h) { ctx -> Bool in
              if ShareLoop.isStill(t) {
                compositor.drawStill(into: ctx, alpha: 1)
              } else if t > ShareLoop.holdEnd {
                compositor.drawStill(into: ctx, alpha: 1 - ShareLoop.progress(t, ShareLoop.holdEnd, ShareLoop.duration))
              } else if !composite || compositor.needsFullRender(t) {
                // No image means no frame: fail, and the caller falls back to the still card (never reuse a stale pooled buffer).
                guard let cg = compositor.fullFrame(t) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
              } else {
                compositor.draw(t, into: ctx)
              }
              return true
            }
            return ok ? b : nil
          }) else { throw EncodeError.render(i) }
          buffer = b
          if ShareLoop.isStill(t) { still = b }
        }
        while !input.isReadyForMoreMediaData {
          try Task.checkCancellation()
          try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(ShareLoop.fps))) else {
          throw EncodeError.writer(writer.error?.localizedDescription ?? "append failed")
        }
        progress(Int(Double(i + 1) / Double(n) * 100))
        await Task.yield() // let the progress bar and Cancel run
      }
      // The last frame lasts to 5.000 s exactly, so the loop seam is clean.
      writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(ShareLoop.fps)))
      input.markAsFinished()
      await writer.finishWriting()
      guard writer.status == .completed else { throw EncodeError.writer(writer.error?.localizedDescription ?? "finish failed") }
    } catch {
      // Any exit, a cancel while waiting for the writer included, closes the writer and removes the partial file.
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      if error is CancellationError { throw EncodeError.cancelled }
      throw error
    }
    return Report(url: url, frames: n, renders: compositor.renders, seconds: Date().timeIntervalSince(started))
  }

  /// A 32BGRA buffer from the adaptor's pool (a fresh one if the pool is not there yet).
  private static func makeBuffer(_ adaptor: AVAssetWriterInputPixelBufferAdaptor, _ w: Int, _ h: Int) -> CVPixelBuffer? {
    var out: CVPixelBuffer?
    if let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, out != nil { return out }
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &out)
    return out
  }

  /// Runs `draw` with a context over the buffer's memory (premultiplied BGRA, sRGB).
  private static func fill(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int, _ draw: (CGContext) -> Bool) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
    return draw(ctx)
  }
}
#endif
