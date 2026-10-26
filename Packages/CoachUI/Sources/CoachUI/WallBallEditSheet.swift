import CoachKit
import SwiftUI

/// The athlete's correction to the wall-ball count. The session result stores it once the CoachKit field lands.
public struct WallBallEdit: Equatable {
  public var validReps: Int
  public var noReps: Int
  public init(validReps: Int, noReps: Int) {
    self.validReps = validReps
    self.noReps = noReps
  }
}

/// Small sheet: valid reps and no-reps, each with big minus / plus buttons.
public struct WallBallEditSheet: View {
  @State private var edit: WallBallEdit
  let onSave: (WallBallEdit) -> Void
  let onCancel: () -> Void

  public init(initial: WallBallEdit, onSave: @escaping (WallBallEdit) -> Void = { _ in }, onCancel: @escaping () -> Void = {}) {
    _edit = State(initialValue: initial)
    self.onSave = onSave
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Edit count").scaledStatement(size: 34).foregroundStyle(PhoneTheme.inkText)
      Text("The watch counts reps by motion. Fix it here if it missed or added some.")
        .scaledFont(15, .semibold).foregroundStyle(PhoneTheme.muted).fixedSize(horizontal: false, vertical: true)
      PhoneCard {
        VStack(spacing: 16) {
          counter("Valid reps", value: $edit.validReps)
          Divider().overlay(PhoneTheme.hairline)
          counter("No-reps", value: $edit.noReps)
        }
      }
      VStack(spacing: 4) {
        PrimaryButton("Save") { onSave(edit) }
        TextLinkButton("Cancel", action: onCancel).frame(maxWidth: .infinity)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PhoneTheme.paper)
  }

  private func counter(_ title: String, value: Binding<Int>) -> some View {
    HStack(spacing: 12) {
      Text(title).scaledFont(17, .semibold).foregroundStyle(PhoneTheme.inkText)
      Spacer()
      roundButton("\u{2212}", label: "Fewer \(title.lowercased())") { value.wrappedValue = max(0, value.wrappedValue - 1) }
      Text("\(value.wrappedValue)").scaledStat().foregroundStyle(PhoneTheme.inkText).frame(minWidth: 52)
      roundButton("+", label: "More \(title.lowercased())") { value.wrappedValue += 1 }
    }
  }

  private func roundButton(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(glyph).scaledFont(28, .heavy).foregroundStyle(PhoneTheme.inkText)
        .frame(width: 48, height: 48)
        .overlay(Circle().stroke(PhoneTheme.inkText, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// The one place the sheet reads its starting counts from: all wall-ball steps, honouring an earlier correction.
public enum WallBallCountAdapter {
  public static func initial(for record: SessionRecord) -> WallBallEdit {
    WallBallEdit(validReps: record.result.validReps, noReps: record.result.noRepCount)
  }
}
