import CoachKit
import Foundation

/// What the watch shows for one moment of a coached session. Plain values so the same views render
/// in the app and in CI snapshots.
public struct StepScreenModel: Equatable {
  public enum Kind: Equatable { case run, time, reps }

  public var kind: Kind
  /// Colour and name come from here.
  public var activity: Activity
  public var title: String
  /// "Transition" while a run is still in its changeover window.
  public var badge: String?
  public var dominant: String
  public var dominantLabel: String
  public var secondary: String
  public var secondaryLabel: String
  public var next: String
  public var isLast: Bool
  /// Seconds behind plan (positive) or ahead (negative).
  public var deltaSeconds: Int
  public var hrBpm: Int?
  public var toast: String?
  public var alarm: String?
  /// Rep count is a low-confidence estimate: show "~" and pulse the +/- buttons.
  public var approximate: Bool

  public init(kind: Kind, activity: Activity, title: String, badge: String? = nil, dominant: String, dominantLabel: String,
              secondary: String, secondaryLabel: String, next: String, isLast: Bool = false, deltaSeconds: Int,
              hrBpm: Int? = nil, toast: String? = nil, alarm: String? = nil, approximate: Bool = false) {
    self.kind = kind
    self.activity = activity
    self.title = title
    self.badge = badge
    self.dominant = dominant
    self.dominantLabel = dominantLabel
    self.secondary = secondary
    self.secondaryLabel = secondaryLabel
    self.next = next
    self.isLast = isLast
    self.deltaSeconds = deltaSeconds
    self.hrBpm = hrBpm
    self.toast = toast
    self.alarm = alarm
    self.approximate = approximate
  }
}

public enum ReadyScreenModel: Equatable {
  case loading
  case noPlan
  case ready(ReadyInfo)
}

public struct ReadyInfo: Equatable {
  public var sessionName: String
  public var targetText: String
  public var athleteChip: String
  /// Warnings that do not block START: "No headphones: cues by vibration", "Heart rate off. The coach still works."
  public var chips: [String]
  public var batteryLine: String?

  public init(sessionName: String, targetText: String, athleteChip: String, chips: [String] = [], batteryLine: String? = nil) {
    self.sessionName = sessionName
    self.targetText = targetText
    self.athleteChip = athleteChip
    self.chips = chips
    self.batteryLine = batteryLine
  }
}

/// One station on the finish strip: its colour, how long it took (or was planned), and whether it was done.
public struct FinishStation: Equatable {
  public let activity: Activity
  public let seconds: Int
  public let done: Bool

  public init(activity: Activity, seconds: Int, done: Bool) {
    self.activity = activity
    self.seconds = seconds
    self.done = done
  }
}

public struct FinishScreenModel: Equatable {
  public enum Mode: Equatable { case saved, saveFailed(missing: Int) }
  public var mode: Mode
  public var totalText: String
  /// "2:14 under target" / "Ended at Row. 5 of 8 stations."
  public var line: String
  public var early: Bool
  public var best: String?
  public var worst: String?
  /// The files are still being closed behind the finish moment.
  public var saving: Bool
  /// While set, UNDO reopens the last step (an accidental FINISH); the recorder is still running.
  public var undoSecondsLeft: Int?
  /// The count-up target, in seconds (0 = just show `totalText`).
  public var totalSeconds: Int
  public var stations: [FinishStation]

  public init(mode: Mode, totalText: String, line: String, early: Bool, best: String? = nil, worst: String? = nil,
              saving: Bool = false, undoSecondsLeft: Int? = nil, totalSeconds: Int = 0, stations: [FinishStation] = []) {
    self.mode = mode
    self.totalText = totalText
    self.line = line
    self.early = early
    self.best = best
    self.worst = worst
    self.saving = saving
    self.undoSecondsLeft = undoSecondsLeft
    self.totalSeconds = totalSeconds
    self.stations = stations
  }

  /// The eight stations of a plan in order; stations not completed are marked so, never shown as 0:00.
  public static func stations(from result: CoachResult) -> [FinishStation] {
    result.rows.filter { !$0.step.isRun }.map {
      FinishStation(activity: $0.step.activity, seconds: $0.actualSeconds ?? $0.step.targetSeconds, done: $0.actualSeconds != nil)
    }
  }
}
