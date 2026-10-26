# station-coach

Watch coach for hybrid fitness racing (working name). This repo is Milestone 1: a recorder that answers whether the watch can do the job and captures labelled data.

- `Watch/` watchOS 10 app: workout session, motion at the highest available rate, tap labels, cue test, battery log, transfer to phone.
- `iOS/` iOS 17 companion: lists received sessions, exports a zip.
- `Packages/CoachKit/` testable logic (labels, file writer, rate maths, cue log, transfer tracking).
- `tools/m1_report.py` prints the four pass marks for a session folder: `python3 tools/m1_report.py <session-folder>`.
- `docs/FORMAT.md` session file format. `docs/SIGNING.md` what is needed for device builds.

Build: `brew install xcodegen && xcodegen generate`, then open `StationCoach.xcodeproj`. CI (GitHub Actions, macOS) is the gate; no signing yet.
