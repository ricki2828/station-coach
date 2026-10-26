import CoachKit
import SwiftUI

/// Wall-ball rest states with the NO REP button, rendered by the screenshot tests beside `ScreenCatalog`.
@MainActor
public enum NoRepScreens {
  static func walls(left: Int, set: Int, noReps: Int, undo: Bool = false) -> StepScreenModel {
    StepScreenModel(kind: .reps, activity: .wallBalls, title: "Wall balls", dominant: "\(left)", dominantLabel: "Reps left, \(left)",
                    secondary: "Set \(set) \u{00B7} 15", secondaryLabel: "Set \(set) of 7, 15 reps", next: "", isLast: true,
                    deltaSeconds: 32, hrBpm: 142, noRepVisible: true, noRepCount: noReps, noRepUndo: undo)
  }

  /// 41 mm: 176 x 215 pt.
  public static let watch41 = CGSize(width: 176, height: 215)

  public static var watchScreens: [CatalogEntry] {
    func watch(_ name: String, _ model: StepScreenModel, size: CGSize = Theme.watch46) -> CatalogEntry {
      CatalogEntry(name: "watch-\(name)", size: size, view: AnyView(WatchChrome(size: size) { CoachStepScreen(model: model, onMissed: {}) }))
    }
    let first = walls(left: 45, set: 4, noReps: 0)
    let two = walls(left: 47, set: 4, noReps: 2)
    let undo = walls(left: 46, set: 4, noReps: 1, undo: true)
    var plain = walls(left: 45, set: 4, noReps: 0)
    plain.noRepVisible = false
    var resumed = walls(left: 46, set: 4, noReps: 1, undo: true)
    resumed.noRepVisible = false
    return [
      watch("station-reps-rest-norep", first),
      watch("station-reps-rest-norep-two", two),
      watch("station-reps-rest-norep-undo", undo),
      watch("station-reps-rest-norep-41mm", first, size: watch41),
      watch("station-reps-rest-norep-two-41mm", two, size: watch41),
      watch("station-reps-rest-norep-undo-41mm", undo, size: watch41),
      watch("station-reps-41mm", plain, size: watch41),
      watch("station-reps-undo-resumed", resumed),
      watch("station-reps-undo-resumed-41mm", resumed, size: watch41),
    ]
  }
}
