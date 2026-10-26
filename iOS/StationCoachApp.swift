import SwiftUI

@main
struct StationCoachApp: App {
  @StateObject private var phone = PhoneTransfer.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(phone)
        .task { phone.activate() }
    }
  }
}
