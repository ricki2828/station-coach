import CoachKit
import SwiftUI

struct HomeView: View {
  @EnvironmentObject var recorder: RecorderController

  var body: some View {
    NavigationStack {
      List {
        Button("Start session") { Task { await recorder.start() } }
          .tint(.green)
        Stepper("Cue every \(recorder.cueInterval)s", value: $recorder.cueInterval, in: 10...300, step: 5)
        NavigationLink("Sessions") { SessionsView() }
        if let m = recorder.statusMessage {
          Text(m).font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Recorder")
    }
  }
}

struct SessionsView: View {
  @ObservedObject private var transfer = WatchTransfer.shared

  var body: some View {
    let sessions = SessionFiles.summaries(in: (try? SessionFiles.defaultRoot()) ?? URL(fileURLWithPath: "/"))
    List {
      Button("Send unsent") { transfer.sendUnsent() }
      Button("Delete sent", role: .destructive) { transfer.deleteAcked() }
      ForEach(sessions) { s in
        VStack(alignment: .leading) {
          Text(s.id).font(.caption2)
          Text("\(s.bytes / 1_000_000) MB  \(transfer.isAcked(s.id) ? "on phone" : "not confirmed")")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Sessions")
  }
}
