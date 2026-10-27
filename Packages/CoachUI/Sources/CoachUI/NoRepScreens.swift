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

  /// The 46 mm base states; `ScreenCatalog.watchSizeSweep` renders them at every case size, 41 mm included.
  public static var watchScreens: [CatalogEntry] {
    func watch(_ name: String, _ model: StepScreenModel) -> CatalogEntry {
      let screen = CoachStepScreen(model: model, onMissed: {})
      return CatalogEntry(name: "watch-\(name)", size: Theme.watch46, view: AnyView(WatchChrome { screen }),
                          sized: { size in AnyView(WatchChrome(size: size) { screen }) })
    }
    var resumed = walls(left: 46, set: 4, noReps: 1, undo: true)
    resumed.noRepVisible = false
    return [
      watch("station-reps-rest-norep", walls(left: 45, set: 4, noReps: 0)),
      watch("station-reps-rest-norep-two", walls(left: 47, set: 4, noReps: 2)),
      watch("station-reps-rest-norep-undo", walls(left: 46, set: 4, noReps: 1, undo: true)),
      watch("station-reps-undo-resumed", resumed),
    ]
  }
}
