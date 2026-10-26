import SwiftUI

@main
struct StationCoachWatchApp: App {
  @StateObject private var recorder = RecorderController()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(recorder)
        .task { WatchTransfer.shared.activate() }
    }
  }
}

struct RootView: View {
  @EnvironmentObject var recorder: RecorderController

  var body: some View {
    switch recorder.phase {
    case .idle: HomeView()
    case .starting: ProgressView("Starting")
    case .running: SessionView()
    case .finishing: ProgressView("Saving")
    }
  }
}
