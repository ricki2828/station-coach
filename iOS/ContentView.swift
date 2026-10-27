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
  /// Called when the activity finishes, whether or not the user chose a target (the documented "done" signal).
  var onDone: (() -> Void)?

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let c = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    c.completionWithItemsHandler = { _, _, _, _ in onDone?() }
    return c
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
  case weekSummary
}

struct ContentView: View {
  @EnvironmentObject var phone: PhoneTransfer
  @StateObject private var app = AppModel(existingSessionIds: PhoneTransfer.shared.coachSessions.map(\.id))
  @Environment(\.scenePhase) private var scenePhase

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
    .onAppear {
      app.evaluateMoments(phone.coachSessions)
      WeeklyNotifier.shared.onOpenSummary = { app.openWeekSummary() }
      if WeeklyNotifier.shared.consumePendingOpen() { app.openWeekSummary() }
      app.refreshNotifyAuth()
    }
    .onChange(of: scenePhase) { _, phase in if phase == .active { app.refreshNotifyAuth() } }
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
      set: { model = $0 }), onOutcome: { phone.resetSendState(); app.finishOnboarding(model, outcome: $0) })
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
          if app.watchNudge && !phone.watchAppInstalled {
            InstallWatchCard(onDismiss: { app.dismissWatchNudge() }).padding(.horizontal, 20).padding(.top, syncFailed ? 0 : 20)
          }
          HomeScreen(model: HomeModel(records: phone.coachSessions, setup: app.raceSetup),
                     week: WeekCardModel.make(phone.loadSummary.sessions, now: Date(), calendar: LoadHistory.calendar()), recoveredIds: phone.recoveredIds,
                     onStart: { phone.resetSendState(); app.start($0) }, onOpenLast: { path.append(.detail($0.id)) }, onOpenPlan: { app.tab = .plan },
                     onOpenWeek: { openSummary() })
        }
      }
      .background(PhoneTheme.paper)
      .refreshable { phone.refresh() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Route.self) { RouteView(route: $0) }
      .onAppear { if phone.watchAppInstalled { app.watchDetected() } }
      .onChange(of: phone.watchAppInstalled) { _, installed in if installed { app.watchDetected() } }
      .onChange(of: app.summaryRequest) { _, _ in openSummary() }
    }
  }

  private func openSummary() {
    if path.last != .weekSummary { path.append(.weekSummary) }
  }

  private var syncFailed: Bool {
    SyncWatchdog.showsFailed(failedId: phone.syncFailedId, newestReadyId: phone.coachSessions.first?.id)
  }
}

struct PlanHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @EnvironmentObject var app: AppModel

  /// The Plan tab's model: the stored choices, the send state and the ghost on offer from History.
  @State private var offers = GhostOfferCache()

  private var model: SetupModel {
    var m = app.setup
    m.send = phone.sendState
    m.ghost = offers.offer(for: m.basePlan, records: phone.coachSessions, excluding: phone.recoveredIds)
    return m
  }

  var body: some View {
    ScrollView {
      SetupScreen(
        model: model,
        notify: app.notifyState, onNotifyToggle: { app.setNotify($0) },
        onDivision: { app.setup.division = $0; changed() },
        onTargetStep: { app.setup.targetSeconds = PlanBuilder.clamped(app.setup.targetSeconds + $0); changed() },
        // The ghost depends on the session type and the wall-ball reps: a change goes back to racing the plan.
        onType: { app.setup.type = $0; app.setup.useGhost = false; changed() },
        onWallBallReps: { app.setup.wallBallReps = $0; app.setup.useGhost = false; changed() },
        onReference: { app.setup.useGhost = $0; changed() },
        onSend: { phone.sendPlan(model.plan) })
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
  @State private var totalsMode: TotalsMode = .week

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(spacing: 0) {
          if syncFailed { SyncFailedCard().padding(.horizontal, 20).padding(.top, 20) }
          HistoryScreen(records: phone.coachSessions, syncPercent: phone.syncPercent, totals: totals, recoveredIds: phone.recoveredIds,
                        onOpen: { path.append(.detail($0.id)) }, onRawFiles: { path.append(.rawFiles) })
        }
      }
      .background(PhoneTheme.paper)
      .refreshable { phone.refresh() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
  }

  private var totals: AnyView {
    let now = Date()
    let cal = LoadHistory.calendar()
    return AnyView(TrainingTotalsCard(
      mode: totalsMode, sessions: phone.loadSummary.sessions, now: now, calendar: cal,
      bestFade: TrainingTotalsCard.bestFade(phone.coachSessions, now: now, calendar: cal),
      onSelect: { totalsMode = $0 }, onOpenSummary: { path.append(.weekSummary) }))
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
    case .weekSummary: WeekSummaryHost()
    }
  }
}

// MARK: Weekly summary

/// The last complete week against its usual, with the Monday-notification opt-in once there is something worth a notice.
struct WeekSummaryHost: View {
  @EnvironmentObject var phone: PhoneTransfer
  @EnvironmentObject var app: AppModel
  @State private var showWhy = false

  var body: some View {
    let s = phone.loadSummary
    let cal = LoadHistory.calendar()
    let compare = LoadCompare.lastComplete(s.sessions, now: Date(), calendar: cal)
    let weeks = LoadHistory.periods(s.sessions, unit: .week, ending: compare.current.start, count: 6, calendar: cal)
    ScrollView {
      VStack(spacing: 0) {
        WeeklySummaryScreen(compare: compare, weeks: weeks, calendar: cal, onWhy: { showWhy = true })
        if app.notifyState.showsOptInCard, WeeklyNotice.content(for: compare) != nil {
          NotifyOptInCard(onYes: { app.setNotify(true) }, onNo: { app.declineNotifyCard() })
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
      }
    }
    .background(PhoneTheme.paper)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showWhy) {
      ScrollView { WhyLoadSheet(period: compare.current, maxHR: s.maxHR) }
        .background(PhoneTheme.paper)
        .presentationDetents([.medium, .large])
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
  @State private var exportedZip: URL?
  /// The video flow: nil is closed. The chooser, the progress and the failure all show in one sheet.
  @State private var flow: ShareFlowState?
  @State private var encodeTask: Task<Void, Never>?
  @State private var videoURL: URL?

  private var record: SessionRecord? { phone.coachSessions.first(where: { $0.id == id }) }

  var body: some View {
    ScrollView {
      if let record {
        SessionDetailScreen(record: record, recovered: phone.recoveredIds.contains(id),
                            onSaveCount: { phone.saveCorrection(WallBallCorrection(validReps: $0.validReps, noReps: $0.noReps), for: id) },
                            onShare: { flow = .choosing }, onExport: { export() })
      } else {
        Text("This session is no longer on the phone.").font(.system(size: 17, weight: .semibold))
          .foregroundStyle(PhoneTheme.muted).padding(20)
      }
    }
    .background(PhoneTheme.paper)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $share, onDismiss: dropTemp) { item in
      ShareSheet(url: item.url, onDone: { if item.url == exportedZip || item.url == videoURL { dropTemp() } })
    }
    .sheet(isPresented: Binding(get: { flow != nil }, set: { if !$0 { cancelFlow() } })) {
      ShareFlowSheet(state: flow ?? .choosing, partial: record?.result.early ?? false,
                     onVideo: { startVideo() }, onImage: { shareImage() }, onCancel: { cancelFlow() })
        .presentationDetents([.height(360)])
    }
    .alert("Couldn't make the card", isPresented: $shareError) { Button("OK", role: .cancel) {} } message: { Text("Try again.") }
  }

  private func dropTemp() {
    if let url = exportedZip { phone.discardExport(url); exportedZip = nil }
    if let url = videoURL { try? FileManager.default.removeItem(at: url); videoURL = nil }
  }

  private func cancelFlow() {
    encodeTask?.cancel()
    encodeTask = nil
    flow = nil
  }

  /// Renders the 5 s loop on the phone. A failure offers the still card instead.
  private func startVideo() {
    guard let record else { return }
    flow = .rendering(percent: 0)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-loop", isDirectory: true)
      .appendingPathComponent("station-coach-\(f.string(from: record.date)).mp4")
    encodeTask = Task { @MainActor in
      do {
        let report = try await ShareLoopEncoder.encode(result: record.result, to: url) { flow = .rendering(percent: $0) }
        print("share loop: \(report.frames) frames, \(report.rendered) rendered, \(String(format: "%.2f", report.seconds)) s")
        guard !Task.isCancelled else { return }
        videoURL = url
        flow = nil
        // Let the chooser sheet finish dismissing before the system share sheet comes up.
        try? await Task.sleep(nanoseconds: 400_000_000)
        share = ShareItem(url: url)
      } catch is CancellationError {
      } catch ShareLoopEncoder.EncodeError.cancelled {
      } catch {
        flow = .failed
      }
    }
  }

  private func shareImage() {
    guard let record else { return }
    flow = nil
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 400_000_000)
      makeCard(record)
    }
  }

  private func makeCard(_ record: SessionRecord) {
    if let url = ShareCard.png(for: record.result) { share = ShareItem(url: url) } else { shareError = true }
  }

  private func export() {
    Task {
      guard let url = try? await phone.exportZip(sessionId: id) else { return }
      exportedZip = url
      share = ShareItem(url: url)
    }
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
  @State private var toDelete: SessionSummary?
  @State private var exportedZip: URL?

  private var totalBytes: Int { phone.sessions.reduce(0) { $0 + $1.bytes } }

  private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

  var body: some View {
    List {
      if phone.sessions.isEmpty {
        Text("No sessions yet. Finish a recording on the watch and keep this app installed; files arrive in the background.")
          .font(.footnote).foregroundStyle(.secondary)
      } else {
        Section {
          Button { exportAll() } label: {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 8) {
                Text(phone.exporting ? "Preparing zip\u{2026}" : "Export all").font(.headline)
                if phone.exporting { ProgressView() }
              }
              Text(phone.exporting ? "Delete is off and files from the watch wait until this is done." : "\(phone.sessions.count) \(phone.sessions.count == 1 ? "session" : "sessions"), \(size(totalBytes)). One zip, shared through the share sheet.")
                .font(.footnote).foregroundStyle(.secondary)
            }
          }
          .disabled(phone.exporting)
        }
      }
      let watchOnly = phone.watchOnlyIds
      if !watchOnly.isEmpty {
        Section("On watch only") {
          ForEach(watchOnly, id: \.self) { id in
            VStack(alignment: .leading, spacing: 2) {
              Text(id).font(.subheadline.monospaced())
              Text("Waiting for the watch. Not on this phone yet; keep both apps open.").font(.footnote).foregroundStyle(.secondary)
            }
            .swipeActions { Button("Forget") { phone.forgetWatchOnly(id) } }
          }
        }
      }
      Section {
        ForEach(phone.sessions) { s in
          Button { export(s.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(s.id).font(.subheadline.monospaced())
              Text("\(s.fileCount) files, \(size(s.bytes))" + (phone.completeIds.contains(s.id) ? "" : "  (incomplete)"))
                .font(.footnote).foregroundStyle(.secondary)
            }
          }
          .disabled(phone.exporting)
          .swipeActions { if !phone.exporting { Button("Delete", role: .destructive) { toDelete = s } } }
        }
      }
      if let error { Text(error).foregroundStyle(.red).font(.footnote) }
    }
    .navigationTitle("Raw files")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { phone.refresh() }
    .sheet(item: $share, onDismiss: dropZip) { item in ShareSheet(url: item.url, onDone: dropZip) }
    .confirmationDialog(deleteTitle, isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
      Button("Delete", role: .destructive) { if let s = toDelete { phone.delete(s.id) }; toDelete = nil }
      Button("Cancel", role: .cancel) { toDelete = nil }
    } message: {
      Text("This removes it from this phone for good. If you have not exported it, it is gone.")
    }
  }

  private var deleteTitle: String {
    guard let s = toDelete else { return "Delete this session?" }
    let d = phone.describe(s.id)
    let when = d.date.map { HistoryFormat.shortDate($0) } ?? s.id
    return "Delete \([d.athlete, when].compactMap { $0 }.joined(separator: ", ")), \(size(s.bytes))?"
  }

  private func dropZip() {
    if let url = exportedZip { phone.discardExport(url); exportedZip = nil }
  }

  private func export(_ id: String) { run { try await phone.exportZip(sessionId: id) } }

  private func exportAll() { run { try await phone.exportZip() } }

  private func run(_ make: @escaping () async throws -> URL) {
    Task {
      do {
        let url = try await make()
        exportedZip = url
        share = ShareItem(url: url)
        error = nil
      } catch PhoneTransfer.ExportError.busy {
        // One zip at a time: the button is disabled, so this is a double tap. Ignore it.
      } catch {
        self.error = "Export failed: \(error.localizedDescription)"
      }
    }
  }
}
