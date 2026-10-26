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

/// Renders the 1080 x 1350 share card to a temp PNG.
@MainActor
enum ShareCard {
  static func png(for result: CoachResult, moment: MomentDisplay? = nil) -> URL? {
    let renderer = ImageRenderer(content: ShareCardV2(result: result, moment: moment).environment(\.colorScheme, .light))
    renderer.scale = ShareCardV2.renderScale
    guard let data = renderer.uiImage?.pngData() else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("station-coach-card.png")
    do { try data.write(to: url) } catch { return nil }
    return url
  }
}

enum Route: Hashable {
  case detail(String)
  case rawFiles
}

struct ContentView: View {
  @EnvironmentObject var phone: PhoneTransfer
  @StateObject private var app = AppModel(existingSessionIds: PhoneTransfer.shared.coachSessions.map(\.id))

  var body: some View {
    Group {
      if app.onboarded {
        TabView(selection: $app.tab) {
          HomeHost().tabItem { Label("Home", systemImage: "house") }.tag(AppModel.Tab.home)
          PlanHost().tabItem { Label("Plan", systemImage: "slider.horizontal.3") }.tag(AppModel.Tab.plan)
          HistoryHost().tabItem { Label("History", systemImage: "list.bullet") }.tag(AppModel.Tab.history)
        }
      } else {
        OnboardingHost()
      }
    }
    .environmentObject(app)
    .tint(PhoneTheme.inkText)
    .preferredColorScheme(.light)
    .onAppear { app.evaluateMoments(phone.coachSessions) }
    .onChange(of: phone.coachSessions) { _, records in app.evaluateMoments(records) }
    .onChange(of: app.onboarded) { _, _ in app.evaluateMoments(phone.coachSessions) }
    .fullScreenCover(item: $app.pendingMoment) { MomentHost(pending: $0) }
  }
}

// MARK: Onboarding

struct OnboardingHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @EnvironmentObject var app: AppModel
  @State private var model = OnboardingModel()

  var body: some View {
    OnboardingFlow(model: Binding(
      get: { var m = model; m.watchAppInstalled = phone.watchAppInstalled; return m },
      set: { model = $0 }), onOutcome: { app.finishOnboarding(model, outcome: $0) })
      .onAppear {
        model.division = app.setup.division
        model.targetSeconds = app.setup.targetSeconds
      }
  }
}

// MARK: Tabs

struct HomeHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @EnvironmentObject var app: AppModel
  @State private var path: [Route] = []

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(spacing: 14) {
          if syncFailed { SyncFailedCard().padding(.horizontal, 20).padding(.top, 20) }
          HomeScreen(model: HomeModel(records: phone.coachSessions, setup: app.raceSetup),
                     onStart: { app.start($0) }, onOpenLast: { path.append(.detail($0.id)) }, onOpenPlan: { app.tab = .plan })
        }
      }
      .background(PhoneTheme.paper)
      .refreshable { phone.refresh() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
  }

  private var syncFailed: Bool {
    SyncWatchdog.showsFailed(failedId: phone.syncFailedId, newestReadyId: phone.coachSessions.first?.id)
  }
}

struct PlanHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @EnvironmentObject var app: AppModel

  var body: some View {
    ScrollView {
      SetupScreen(
        model: { var m = app.setup; m.send = phone.sendState; return m }(),
        onDivision: { app.setup.division = $0; changed() },
        onTargetStep: { app.setup.targetSeconds = PlanBuilder.clamped(app.setup.targetSeconds + $0); changed() },
        onType: { app.setup.type = $0; changed() },
        onWallBallReps: { app.setup.wallBallReps = $0; changed() },
        onSend: { phone.sendPlan(app.setup.plan) })
    }
    .background(PhoneTheme.paper)
  }

  private func changed() {
    phone.resetSendState()
    app.setupChanged()
  }
}

struct HistoryHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @State private var path: [Route] = []

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(spacing: 0) {
          if syncFailed { SyncFailedCard().padding(.horizontal, 20).padding(.top, 20) }
          HistoryScreen(records: phone.coachSessions, syncPercent: phone.syncPercent,
                        onOpen: { path.append(.detail($0.id)) }, onRawFiles: { path.append(.rawFiles) })
        }
      }
      .background(PhoneTheme.paper)
      .refreshable { phone.refresh() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
  }

  private var syncFailed: Bool {
    SyncWatchdog.showsFailed(failedId: phone.syncFailedId, newestReadyId: phone.coachSessions.first?.id)
  }
}

struct RouteView: View {
  let route: Route

  var body: some View {
    switch route {
    case .detail(let id): SessionDetailHost(id: id)
    case .rawFiles: RawFilesHost()
    }
  }
}

// MARK: Detail

/// The one session detail, pushed from Home or History.
struct SessionDetailHost: View {
  let id: String
  @EnvironmentObject var phone: PhoneTransfer
  @State private var share: ShareItem?
  @State private var shareError = false

  var body: some View {
    ScrollView {
      if let record = phone.coachSessions.first(where: { $0.id == id }) {
        SessionDetailScreen(record: record,
                            onSaveCount: { phone.saveCorrection(WallBallCorrection(validReps: $0.validReps, noReps: $0.noReps), for: id) },
                            onShare: { makeCard(record) }, onExport: { export() })
      } else {
        Text("This session is no longer on the phone.").font(.system(size: 17, weight: .semibold))
          .foregroundStyle(PhoneTheme.muted).padding(20)
      }
    }
    .background(PhoneTheme.paper)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $share) { ShareSheet(url: $0.url) }
    .alert("Couldn't make the card", isPresented: $shareError) { Button("OK", role: .cancel) {} } message: { Text("Try again.") }
  }

  private func makeCard(_ record: SessionRecord) {
    if let url = ShareCard.png(for: record.result) { share = ShareItem(url: url) } else { shareError = true }
  }

  private func export() {
    guard let url = try? phone.zip(id) else { return }
    share = ShareItem(url: url)
  }
}

// MARK: Moment

struct MomentHost: View {
  let pending: PendingMoment
  @EnvironmentObject var app: AppModel
  @State private var share: ShareItem?

  var body: some View {
    MomentScreen(display: pending.display, result: pending.record.result,
                 onNice: { app.pendingMoment = nil },
                 onShare: {
                   if let url = ShareCard.png(for: pending.record.result, moment: pending.display) { share = ShareItem(url: url) }
                 })
      .sheet(item: $share) { ShareSheet(url: $0.url) }
  }
}

// MARK: Raw files

/// Every received session folder, exportable as a zip (the M1 view), behind History's "Raw files" link.
struct RawFilesHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @State private var share: ShareItem?
  @State private var error: String?

  var body: some View {
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
    .navigationTitle("Raw files")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { phone.refresh() }
    .sheet(item: $share) { ShareSheet(url: $0.url) }
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
