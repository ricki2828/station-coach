import CoachKit
import SwiftUI

/// Wall-ball rest states with the NO REP button, rendered by the screenshot tests beside `ScreenCatalog`.
@MainActor
public enum NoRepScreens {
  private static func walls(left: Int, set: Int, noReps: Int) -> StepScreenModel {
    StepScreenModel(kind: .reps, activity: .wallBalls, title: "Wall balls", dominant: "\(left)", dominantLabel: "Reps left, \(left)",
                    secondary: "Set \(set) \u{00B7} 15", secondaryLabel: "Set \(set) of 7, 15 reps", next: "", isLast: true,
                    deltaSeconds: 32, hrBpm: 142, noRepVisible: true, noRepCount: noReps)
  }

  public static var watchScreens: [CatalogEntry] {
    func watch(_ name: String, _ model: StepScreenModel) -> CatalogEntry {
      CatalogEntry(name: "watch-\(name)", size: Theme.watch46, view: AnyView(WatchChrome { CoachStepScreen(model: model, onMissed: {}) }))
    }
    return [
      watch("station-reps-rest-norep", walls(left: 45, set: 4, noReps: 0)),
      watch("station-reps-rest-norep-two", walls(left: 47, set: 4, noReps: 2)),
    ]
  }
}
