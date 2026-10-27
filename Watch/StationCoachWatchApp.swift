import CoachKit
import CoachUI
import SwiftUI
import WatchKit

/// The system calls `handleActiveWorkoutRecovery` after it relaunches the app for a workout session that was still
/// running when the app died. The work is handed to `RecoveryCoordinator`, which waits for the controllers to exist.
final class AppDelegate: NSObject, WKApplicationDelegate {
  func handleActiveWorkoutRecovery() {
    Task { @MainActor in RecoveryCoordinator.shared.recoverRequested() }
  }
}

@MainActor
final class RecoveryCoordinator {
  static let shared = RecoveryCoordinator()
  private let trigger = RecoveryTrigger()

  func install(_ handler: @escaping @MainActor () async -> Void) {
    trigger.install { Task { @MainActor in await handler() } }
  }

  func recoverRequested() { trigger.request() }
}

@main
struct StationCoachWatchApp: App {
  @WKApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var recorder: RecorderController
  @StateObject private var coach: CoachController

  init() {
    let r = RecorderController()
    _recorder = StateObject(wrappedValue: r)
    let c = CoachController(recorder: r)
    _coach = StateObject(wrappedValue: c)
    // Resume the coached session if the app was killed mid-session; otherwise end the orphaned workout and keep the files.
    RecoveryCoordinator.shared.install { [weak r, weak c] in
      guard let r, let c else { return }
      if await c.resume() { return }
      await r.abandonRecovered()
    }
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
      CoachFinishScreen(model: finish, animate: true, onDone: { coach.dismissFinish() }, onUndo: { coach.undoFinish() })
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
