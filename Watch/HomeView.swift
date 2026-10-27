import CoachKit
import SwiftUI

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

  private var sentCount: Int {
    guard let root = try? SessionFiles.defaultRoot() else { return 0 }
    return SessionFiles.summaries(in: root).filter { transfer.isAcked($0.id) }.count
  }

  var body: some View {
    let sessions = SessionFiles.summaries(in: (try? SessionFiles.defaultRoot()) ?? URL(fileURLWithPath: "/"))
    List {
      Button("Send unsent") { transfer.sendUnsent() }
      Button("Delete sent", role: .destructive) { confirmDelete = true }
        .confirmationDialog("Delete \(sentCount) sent \(sentCount == 1 ? "session" : "sessions") from the watch?", isPresented: $confirmDelete, titleVisibility: .visible) {
          Button("Delete \(sentCount)", role: .destructive) { transfer.deleteAcked() }
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
}
