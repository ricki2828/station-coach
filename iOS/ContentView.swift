import CoachKit
import CoachUI
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
  var body: some View {
    TabView {
      SetupHost().tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
      SummaryHost().tabItem { Label("Summary", systemImage: "chart.bar") }
      SessionsHost().tabItem { Label("Sessions", systemImage: "folder") }
    }
    .tint(Theme.finishFlood)
    .preferredColorScheme(.dark)
  }
}

/// Division, target and session type; remembered between launches.
struct SetupHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @State private var model: SetupModel = Self.load()

  var body: some View {
    ScrollView {
      SetupScreen(
        model: { var m = model; m.send = phone.sendState; return m }(),
        onDivision: { model.division = $0; changed() },
        onTargetStep: { model.targetSeconds = PlanBuilder.clamped(model.targetSeconds + $0); changed() },
        onType: { model.type = $0; changed() },
        onSend: { phone.sendPlan(model.plan) })
    }
    .background(Theme.ink)
  }

  private func changed() {
    phone.resetSendState()
    let d = UserDefaults.standard
    d.set(model.division.rawValue, forKey: "setup.division")
    d.set(model.targetSeconds, forKey: "setup.target")
    d.set(model.type.rawValue, forKey: "setup.type")
  }

  private static func load() -> SetupModel {
    let d = UserDefaults.standard
    var m = SetupModel()
    if let r = d.string(forKey: "setup.division"), let v = Division(rawValue: r) { m.division = v }
    if let r = d.string(forKey: "setup.type"), let v = SessionType(rawValue: r) { m.type = v }
    if d.integer(forKey: "setup.target") > 0 { m.targetSeconds = d.integer(forKey: "setup.target") }
    return m
  }
}

/// Insight, table, chart, wall balls, share card, export for the newest coached session.
struct SummaryHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @State private var share: ShareItem?
  @State private var shareError = false

  var body: some View {
    ScrollView {
      SummaryScreen(state: state, shareError: shareError, onShare: makeCard, onExport: export)
    }
    .background(Theme.ink)
    .refreshable { phone.refresh() }
    .sheet(item: $share) { ShareSheet(url: $0.url) }
  }

  private var state: SummaryState {
    if let latest = phone.latestCoach { return .ready(latest.result) }
    if let p = phone.syncPercent { return .syncing(percent: p) }
    return .empty
  }

  @MainActor
  private func makeCard() {
    guard let result = phone.latestCoach?.result else { return }
    let renderer = ImageRenderer(content: ShareCardView(result: result))
    renderer.scale = 3
    guard let png = renderer.uiImage?.pngData() else { shareError = true; return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-card.png")
    do {
      try png.write(to: url)
      shareError = false
      share = ShareItem(url: url)
    } catch {
      shareError = true
    }
  }

  private func export() {
    guard let id = phone.latestCoach?.id, let url = try? phone.zip(id) else { return }
    share = ShareItem(url: url)
  }
}

/// Every received session folder, exportable as a zip (the M1 view).
struct SessionsHost: View {
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
