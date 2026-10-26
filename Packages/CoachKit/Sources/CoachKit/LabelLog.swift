import Foundation

public struct LabelEvent: Equatable {
  public enum Kind: String { case set, undo }
  public let kind: Kind
  public let epochMs: Int64
  public let activity: Activity

  public init(kind: Kind, epochMs: Int64, activity: Activity) {
    self.kind = kind
    self.epochMs = epochMs
    self.activity = activity
  }

  public static let csvHeader = "epoch_ms,event,activity"
  public var csvLine: String { "\(epochMs),\(kind.rawValue),\(activity.rawValue)" }
}

public struct LabelInterval: Equatable {
  public let activity: Activity
  public let startMs: Int64
  public let endMs: Int64
}

/// Tap-to-label state. `set` pushes; `undo` pops the last set, so the label before it resumes
/// (the mistaken tap's time goes back to the previous label). A tap on the current label is a no-op.
public struct LabelLog {
  struct Entry: Equatable {
    let activity: Activity
    let startMs: Int64
  }

  private var stack: [Entry] = []

  public init() {}

  public var current: Activity? { stack.last?.activity }

  @discardableResult
  public mutating func set(_ activity: Activity, at ms: Int64) -> LabelEvent? {
    if current == activity { return nil }
    stack.append(Entry(activity: activity, startMs: ms))
    return LabelEvent(kind: .set, epochMs: ms, activity: activity)
  }

  @discardableResult
  public mutating func undo(at ms: Int64) -> LabelEvent? {
    guard let last = stack.popLast() else { return nil }
    return LabelEvent(kind: .undo, epochMs: ms, activity: last.activity)
  }

  /// Each surviving label runs until the next one starts; the last runs to `endMs`.
  public func intervals(endMs: Int64) -> [LabelInterval] {
    stack.enumerated().map { i, e in
      LabelInterval(activity: e.activity, startMs: e.startMs, endMs: i + 1 < stack.count ? stack[i + 1].startMs : endMs)
    }
  }

  /// Rebuilds state from a logged event list (what `labels.csv` holds).
  public static func replay(_ events: [LabelEvent]) -> LabelLog {
    var log = LabelLog()
    for e in events {
      switch e.kind {
      case .set: log.set(e.activity, at: e.epochMs)
      case .undo: log.undo(at: e.epochMs)
      }
    }
    return log
  }
}
