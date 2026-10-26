import Foundation

/// Decides which newly synced session, if any, gets a phone moment. Each session id is offered once.
public enum MomentTrigger {
  public struct Outcome: Equatable {
    public let record: SessionRecord
    public let moment: Moment
    /// Date of the earlier best, for the "faster than 24 Oct" line.
    public let previousBestDate: Date?
    /// Every id to add to the seen set (the offered one and any older unseen ones).
    public let markSeen: Set<String>
  }

  /// The newest unseen record is judged against everything older than it. Older unseen records are marked seen
  /// without a moment, so a burst of syncs shows at most one.
  /// Returns the ids to mark seen even when no moment is earned.
  public static func evaluate(records: [SessionRecord], seen: Set<String>) -> (outcome: Outcome?, markSeen: Set<String>) {
    let sorted = SessionRecord.sorted(records)
    let unseen = sorted.filter { !seen.contains($0.id) }
    guard let newest = unseen.first else { return (nil, []) }
    let older = sorted.filter { $0.date < newest.date && $0.id != newest.id }
    let mark = Set(unseen.map(\.id))
    guard let moment = MomentPicker.pick(previous: older, new: newest) else { return (nil, mark) }
    var bestDate: Date?
    if case .best(let type, let previousBest) = moment {
      bestDate = older.first { $0.type == type && $0.isComplete && $0.result.totalSeconds == previousBest }?.date
    }
    return (Outcome(record: newest, moment: moment, previousBestDate: bestDate, markSeen: mark), mark)
  }
}
