import SwiftUI
import UserNotifications

@main
struct StationCoachApp: App {
  @StateObject private var phone = PhoneTransfer.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    UNUserNotificationCenter.current().delegate = WeeklyNotifier.shared
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(phone)
        .task { phone.activate() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { phone.appBecameActive() }
        }
    }
  }
}
