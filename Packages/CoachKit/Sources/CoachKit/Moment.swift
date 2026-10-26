import Foundation

/// A rare phone moment shown after a session syncs. At most one per session; the picker lives with the history model.
public enum Moment: Equatable {
  /// First session of this type.
  case first(SessionType)
  /// New best total for this type; `previousBest` is the earlier best total in seconds.
  case best(SessionType, previousBest: Int)
  /// Lowest run fade yet; `previous` is the earlier lowest fade in seconds.
  case leastFade(previous: Int)
}
