import CoachUI
import SwiftUI

@main
struct StationCoachWatchApp: App {
  @StateObject private var recorder: RecorderController
  @StateObject private var coach: CoachController

  init() {
    let r = RecorderController()
    _recorder = StateObject(wrappedValue: r)
    _coach = StateObject(wrappedValue: CoachController(recorder: r))
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(recorder)
        .environmentObject(coach)
        .task { WatchTransfer.shared.activate() }
    }
  }
}

struct RootView: View {
  @EnvironmentObject var recorder: RecorderController
  @EnvironmentObject var coach: CoachController

  var body: some View {
    if let finish = coach.finish {
      CoachFinishScreen(model: finish, onDone: { coach.dismissFinish() }, onUndo: { coach.undoFinish() })
    } else {
      switch recorder.phase {
      case .idle: IdleHost()
      case .starting: ProgressView("Starting")
      case .running: if coach.active { CoachRunningHost() } else { SessionView() }
      case .finishing: ProgressView("Saving")
      }
    }
  }
}
