import CoachKit
import SwiftUI
import WatchConnectivity

struct HomeView: View {
  @EnvironmentObject var recorder: RecorderController

  var body: some View {
    List {
      if !recorder.unfinished.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Last session stopped unexpectedly").font(.footnote.bold()).foregroundStyle(.red)
          Text("Data is kept. Keep it, then start a new session.").font(.caption2)
          Button("Keep and send") { recorder.keepUnfinished() }
        }
      }
      Picker("Athlete", selection: $recorder.athlete) {
        ForEach(RecorderController.athleteCodes, id: \.self) { Text($0).tag($0) }
      }
      Picker("Wrist", selection: $recorder.wrist) {
        Text("Left").tag("left")
        Text("Right").tag("right")
      }
      Button("Record only: \(recorder.athlete) \(recorder.wrist)") { Task { await recorder.start() } }
        .tint(.green)
      Stepper("Cue every \(recorder.cueInterval)s", value: $recorder.cueInterval, in: 10...300, step: 5)
      Picker("Store motion", selection: $recorder.storeHz) {
        ForEach([25, 50, 100, 200], id: \.self) { Text("\($0) Hz").tag($0) }
      }
      Picker("Cue audio", selection: $recorder.audioMode) {
        ForEach(AudioMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      NavigationLink("Sessions") { SessionsView() }
      if let m = recorder.statusMessage {
        Text(m).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Recorder")
  }
}

struct SessionsView: View {
  @ObservedObject private var transfer = WatchTransfer.shared
  @State private var confirmDelete = false
  /// The sent sessions the dialog was opened for. Deleting exactly these, not whatever is acked at the tap, keeps the count honest.
  @State private var toDelete: [String] = []

  private func sentIds() -> [String] {
    guard let root = try? SessionFiles.defaultRoot() else { return [] }
    return SessionFiles.summaries(in: root).map(\.id).filter { transfer.isAcked($0) }
  }

  var body: some View {
    let sessions = SessionFiles.summaries(in: (try? SessionFiles.defaultRoot()) ?? URL(fileURLWithPath: "/"))
    List {
      Button("Send unsent") { transfer.sendUnsent() }
      Button("Delete sent", role: .destructive) { toDelete = sentIds(); confirmDelete = true }
        .confirmationDialog("Delete \(toDelete.count) sent \(toDelete.count == 1 ? "session" : "sessions") from the watch?", isPresented: $confirmDelete, titleVisibility: .visible) {
          Button("Delete \(toDelete.count)", role: .destructive) { deleteSent(toDelete) }
          Button("Cancel", role: .cancel) {}
        }
      ForEach(sessions) { s in
        VStack(alignment: .leading) {
          Text(s.id).font(.caption2)
          Text("\(s.bytes / 1_000_000) MB  \(transfer.isAcked(s.id) ? "on phone" : "on watch only")")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Sessions")
  }

  /// Same effect as `WatchTransfer.deleteAcked()`, limited to the ids shown in the dialog. A session acked after the dialog opened stays.
  private func deleteSent(_ ids: [String]) {
    guard let root = try? SessionFiles.defaultRoot() else { return }
    let still = ids.filter { transfer.isAcked($0) }
    for id in still { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
    if !still.isEmpty, WCSession.isSupported(), WCSession.default.activationState == .activated {
      WCSession.default.transferUserInfo(["gone": still]) // the phone clears anything it was waiting for
    }
    transfer.objectWillChange.send()
  }
}
