import CoachKit
import SwiftUI

struct SessionView: View {
  @EnvironmentObject var recorder: RecorderController
  @State private var confirmStop = false
  @Environment(\.isLuminanceReduced) private var dimmed

  private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        if let alarm = recorder.alarm {
          VStack(spacing: 2) {
            Text("RECORDING AT RISK").font(.caption2.bold())
            Text(alarm).font(.caption2)
            Button("OK") { recorder.dismissAlarm() }
          }
          .frame(maxWidth: .infinity)
          .padding(4)
          .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
        }
        header
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(Activity.allCases) { activity in
            Button { recorder.tap(activity) } label: {
              Text(activity.buttonTitle)
                .font(.caption2.bold())
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .tint(recorder.currentLabel == activity ? .green : .gray)
          }
        }
        status
        Button("Didn't hear last cue") { recorder.flagMissedCue() }
          .font(.caption2)
        Button("End session", role: .destructive) { confirmStop = true }
      }
    }
    .alert("End session?", isPresented: $confirmStop) {
      Button("End", role: .destructive) { Task { await recorder.stop() } }
      Button("Keep recording", role: .cancel) {}
    }
  }

  private var header: some View {
    VStack(spacing: 2) {
      Text(recorder.currentLabel?.buttonTitle ?? "No label")
        .font(.title3.bold())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      TimelineView(.periodic(from: .now, by: 1)) { ctx in
        Text(Self.clock(ctx.date.timeIntervalSince(recorder.startedAt), seconds: !dimmed))
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Text("hold to undo").font(.system(size: 10)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onLongPressGesture(minimumDuration: 0.8) { recorder.undo() }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("HR \(recorder.heartRate.map(String.init) ?? "-")  Bat \(recorder.batteryPercent.map { "\($0)%" } ?? "-")")
      Text("\(recorder.motionApi == "CMBatchedSensorManager" ? "batched" : "legacy") \(recorder.rawHz.map { "\($0) Hz" } ?? "-")  cues \(recorder.cueCount)")
      Text(recorder.lastCue).lineLimit(2)
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func clock(_ seconds: TimeInterval, seconds showSeconds: Bool = true) -> String {
    let s = max(0, Int(seconds))
    if !showSeconds { return String(format: "%d:%02d", s / 3600, (s / 60) % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
  }
}
