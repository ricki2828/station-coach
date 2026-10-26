import SwiftUI

@main
struct StationCoachApp: App {
  @StateObject private var phone = PhoneTransfer.shared
  @Environment(\.scenePhase) private var scenePhase

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
