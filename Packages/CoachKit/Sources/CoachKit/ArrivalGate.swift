import Foundation

/// Holds incoming session-file renames while a zip is being built, so a file cannot land mid-zip.
/// Not thread-safe: use on one queue (the phone uses main). `submit` runs work at once when the gate is open,
/// and queues it, in order, while closed; `open()` runs everything queued.
public final class ArrivalGate {
  public private(set) var isClosed = false
  private var held: [() -> Void] = []

  public init() {}

  public var heldCount: Int { held.count }

  public func close() { isClosed = true }

  public func submit(_ work: @escaping () -> Void) {
    if isClosed { held.append(work) } else { work() }
  }

  /// Opens the gate and runs the held work in arrival order.
  public func open() {
    isClosed = false
    let work = held
    held = []
    for w in work { w() }
  }
}
