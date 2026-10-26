import CoachKit
import SwiftUI
import UIKit

struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
  @EnvironmentObject var phone: PhoneTransfer
  @State private var share: ShareItem?
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        if phone.sessions.isEmpty {
          Text("No sessions yet. Finish a recording on the watch and keep this app installed; files arrive in the background.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(phone.sessions) { s in
          Button { export(s.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(s.id).font(.subheadline.monospaced())
              Text("\(s.fileCount) files, \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))"
                   + (phone.completeIds.contains(s.id) ? "" : "  (incomplete)"))
                .font(.footnote).foregroundStyle(.secondary)
            }
          }
          .swipeActions { Button("Delete", role: .destructive) { phone.delete(s.id) } }
        }
        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
      }
      .navigationTitle("Sessions")
      .refreshable { phone.refresh() }
      .sheet(item: $share) { ShareSheet(url: $0.url) }
    }
  }

  private func export(_ id: String) {
    do {
      share = ShareItem(url: try phone.zip(id))
      error = nil
    } catch {
      self.error = "Export failed: \(error.localizedDescription)"
    }
  }
}
