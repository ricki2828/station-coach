import CoachKit
import CoachUI
import SwiftUI

/// The idle screen: the coach's Ready screen, with the M1 recorder tools one scroll below.
struct IdleHost: View {
  @EnvironmentObject var recorder: RecorderController
  @EnvironmentObject var coach: CoachController
  @ObservedObject private var transfer = WatchTransfer.shared
  @State private var showRecorder = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 8) {
          // Re-read the route and battery now and then so the chips stay true.
          TimelineView(.periodic(from: .now, by: 5)) { _ in
            CoachReadyScreen(model: coach.readyModel, onStart: { Task { await coach.start() } }, onRecorderOnly: { showRecorder = true })
              .frame(minHeight: 232)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
          if !recorder.unfinished.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Last session stopped unexpectedly").font(.footnote.bold()).foregroundStyle(.red)
              Button("Keep and send") { recorder.keepUnfinished() }
            }
          }
          NavigationLink("Recorder tools") { HomeView() }
        }
      }
      .navigationDestination(isPresented: $showRecorder) { HomeView() }
      .onAppear { coach.refreshAudioRoute() }
    }
  }
}

/// A coached session: one screen per phase, long press for Undo / End.
struct CoachRunningHost: View {
  @EnvironmentObject var recorder: RecorderController
  @EnvironmentObject var coach: CoachController

  var body: some View {
    Group {
      if let step = coach.leftover {
        CoachLeftoverScreen(title: CoachCopy.leftoverTitle(step), activity: step.activity,
                            onNow: { coach.doLeftover() }, onWithout: { coach.finishWithoutLeftover() }, onUndo: { coach.undo() })
      } else if let model = coach.screen {
        CoachStepScreen(
          model: model,
          onNext: { coach.advance() },
          onPlus: { coach.adjustReps(1) },
          onMinus: { coach.adjustReps(-1) },
          onNoRep: { coach.noRep() },
          onNoRepUndo: { coach.undoNoRep() },
          onMissed: { recorder.flagMissedCue() },
          onAlarm: { recorder.dismissAlarm() })
      } else {
        ProgressView()
      }
    }
    // 1.5 s: longer than the 1.0 s HOLD TO FINISH, so holding FINISH can never open the menu first.
    .onLongPressGesture(minimumDuration: 1.5) { coach.showMenu = true }
    // One sheet for the menu and "Skip Row?": opening the second from the first never dismisses and re-presents.
    .sheet(isPresented: Binding(
      get: { coach.showMenu || coach.showSkipConfirm },
      set: { if !$0 { coach.showMenu = false; coach.showSkipConfirm = false } })
    ) {
      if coach.showSkipConfirm, let step = coach.skipStep {
        CoachSkipConfirmScreen(title: CoachCopy.skipTitle(step), activity: step.activity, canLater: coach.canDoItLater,
                               onLater: { coach.skip(later: true) }, onSkip: { coach.skip(later: false) },
                               onBack: { coach.showSkipConfirm = false })
      } else {
        CoachMenuScreen(canSkip: coach.canSkipHere, onUndo: { coach.undo() }, onSkip: { coach.requestSkip() },
                        onEnd: { coach.endEarly() }, onCancel: { coach.showMenu = false })
      }
    }
  }
}
