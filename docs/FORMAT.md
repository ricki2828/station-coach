# Session format, version 1

One folder per session: `<UTC start as yyyyMMdd'T'HHmmss'Z'>-<6 hex>`. Everything is UTF-8 CSV with a header row, appended while recording and flushed (fsync) every 60 s, so a crash or flat battery keeps all but the last minute. All timestamps are Unix epoch time: `epoch_ms` is milliseconds, `epoch_us` is microseconds. Motion timestamps come from the sensor (boot-relative) shifted to epoch with the offset sampled at app start.

| File | Columns | Written |
|---|---|---|
| `manifest.json` | `formatVersion`, `sessionId`, `startedAtEpochMs`, `endedAtEpochMs`, `device`, `osVersion`, `appVersion`, `workoutActivityType`, `motionApi`, `requestedHz`, `storeHz`, `cueIntervalSec`, `audioMode`, `athlete` (code such as A1, never a name), `wrist` (`left`/`right`), `crownOrientation` (`left`/`right`, the side the crown is on; absent in older sessions), `recovered` (true if closed after an unexpected stop), `labelSource` (`athlete_taps` or `coach`), `transitionLabelSeconds` (coach sessions: a run after a station is labelled `transition` for its first this-many seconds, a time rule and not an observation), `files` | at start, rewritten at finish (`endedAtEpochMs` and `files` are absent from a session that never finished) |
| `labels.csv` | `epoch_ms,event,activity` | on each tap / undo |
| `cues.csv` | `epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail,audio_mode` | per cue event |
| `battery.csv` | `epoch_ms,level,state` | every 60 s |
| `hr.csv` | `epoch_ms,bpm` | on each HealthKit heart-rate sample |
| `accel.csv` | `epoch_us,x,y,z` (g) | decimated to at most `storeHz` (100) |
| `motion.csv` | `epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z` (user acceleration g, rotation rate rad/s, gravity g) | decimated to at most `storeHz` |
| `rates.csv` | `epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz` | every 60 s, one row per stream, for that window |
| `events.csv` | `epoch_ms,kind,detail` | session start/end, motion API, workout state, audio route changes, errors |

## Schemas
The JSON files are described by JSON Schema (draft 7) in `docs/schema/`: `manifest.schema.json`, `coach.schema.json` and `plan.schema.json` (coach.json embeds the plan) and `phone-correction.schema.json`. They are strict (`additionalProperties: false`), so a new field needs a schema change; `tools/tests/test_schema.py` validates the fixtures, and `tools/fixtures/swift-contract/*.json` (compared with real encoded CoachKit structs by `SchemaContractTests.swift`, regenerate with `SC_UPDATE_CONTRACT=1 swift test --filter SchemaContractTests`), against them and checks that the schema's enums and manifest property names still match the Swift sources. The CSV files are described by the table above and `SessionStream` headers. A non-Apple source (see `SessionSource.swift`) is conformant if its folder passes these schemas.

## Coached sessions
A session started from the coach (plan from the phone) is the same folder plus `coach.json`, written at the end by the watch:
`plan` (division, session type, race target, `steps` with per-step targets and wall-ball set structure, `transitionSeconds`), `splits` (`stepIndex`, `startMs`, `endMs`; a step never started has no split, a step not finished has no `endMs`, except that `SessionMachine.end` closes the step in progress when a session ends early, so on an early session the last split has an `endMs` but was quit, not completed), `early`, `repTimesMs` (heuristic wall-ball rep times, epoch ms), `repCorrection` (net manual +/-), `startedAtEpochMs`, `endedAtEpochMs`.

Racing a ghost: `plan.ghostSplits` (optional, one integer per step, in plan order) holds the seconds each step took in the session being raced, and the watch measures its live delta against those instead of the step targets (`DeltaMath` uses `referenceSeconds`). Absent = race the plan; an array whose length is not the step count is ignored. Only a finished session of the same type and step structure (same wall-ball reps) with no unfinished or skipped step can be a ghost. The phone sets it from the "Race against" choice on the Plan tab (default: plan); it is stored in `coach.json` so the detail screen can say how the session did against it. History and training load still compare against the plan targets.

Wall-ball no-reps (all optional; files without them decode as no no-reps):
- `noReps`: one event per NO REP tap on the watch, in order: `tMs` (epoch ms), `setIndex` (0-based set of the plan step), `stepIndex` (plan step; absent = the first wall-ball step). `repTimesMs` still lists every counted throw, no-reps included.
- `wallBallCorrection`: `{ "validReps": Int, "noReps": Int }`, replacing the watch's counts. The phone's Edit count sheet does not write it into `coach.json`: it writes `phone-correction.json` (the same object, clamped to 0...300 valid and 0...100 no-reps) next to it, and the phone applies that over `coach.json` on load. The watch never sends this file, so a re-sent `coach.json` cannot undo a correction. It is hidden from the Raw files counts but is in the export zip. Early test builds wrote a bare Int (total throws); it still decodes, with the logged taps as `noReps`.
- Derived, not stored: `noRepCount` = `wallBallCorrection.noReps` else `noReps.count`; `validReps` = `wallBallCorrection.validReps` else `repTimesMs.count + repCorrection - noReps.count`; `totalThrows` = `validReps + noRepCount`. The per-set split (`noRepsBySet`) and the late-no-reps insight use the logged taps only.
In a coached session the cue timer is off, so `manifest.cueIntervalSec` is `0` and the report does not expect periodic cues; cues come from the coach and are logged in `cues.csv` as before. Coach phase changes write `labels.csv` automatically (and `rest` once the session is finished, until the files close): `run`, `transition` (the first `transitionSeconds` of a run that follows a station) and the station activities.
The wall-ball rep count is a beta heuristic (peaks in wrist acceleration magnitude) and counts down on the watch; the athlete corrects it with +/-.

## Crash recovery (coached sessions)
While a coached session runs, the watch keeps `coach-checkpoint.json` in the session folder (plus `coach-checkpoint.prev.json`, the copy before the latest write). It holds the session plan, the splits so far, the wall-ball rep times, manual +/- corrections, NO REP taps and which cues were already said. It is rewritten (temporary file, fsync, rename) on each change: step change, NO REP, +/- and undo at once, and a counted wall-ball rep or a fired mid-station / jog-in cue within a second (detected by the 1 s tick). Nothing is written when nothing changed. A clean finish deletes both files before the manifest's `files` list is made, so they are never sent to the phone. Fields: `version` (1), `sessionId` (must equal the folder name), `savedAtEpochMs`, `seq` (counts up; the newer readable copy wins), `state`.

If the app is killed mid-session there are two outcomes, and both are logged:
- **Resumed.** The system relaunches the app for the still-running workout session (`handleActiveWorkoutRecovery`). Only the newest unfinished folder is considered, and only if the recovered workout started within 60 s of the folder's `startedAtEpochMs`; otherwise nothing is resumed. The watch appends to the same files (no header is written twice), `manifest.json` gains `resumed` (count of resumes, absent = never; motion and heart-rate files have a gap at each), a half-written last line is ended with a newline (see below), and the watch restores the coach from the newest valid checkpoint (at most a few seconds of step state is lost) and logs `events.csv` `recovered_resume` (`step=<n> splits=<n> seq=<n>`, plus `backup` if the `.prev` copy was used). The session then finishes normally and `coach.json` has the whole session. The `labels.csv` gets the current activity again after the gap.
- **Not resumed** (no checkpoint, an unreadable one, older than 6 hours, or the workout session could not be reattached). Closing the unfinished folder (automatic after a failed resume, or "Keep" on the watch) writes `coach.json` from the checkpoint with `early: true`, the open step closed at the folder's last write time, so the phone's History lists it as ended early. `manifest.json` gets `recovered: true`. An existing `coach.json` is never overwritten. A checkpoint that is unreadable or names steps the plan does not have is deleted without making a `coach.json`.

**Torn rows.** A kill can leave the last line of any CSV cut short (fewer columns than the header, or a number cut off). Resume ends that line with `\n` and carries on, so a resumed session can have ONE short row in the middle of a stream, followed by a time gap. It is not repaired or deleted. Readers must skip any row whose column count differs from the header (and any row that fails to parse) instead of failing; the gap is also the cue to treat samples before and after as separate stretches. A session closed without a resume keeps its torn last row at the end of the file.

**Uncoached (M1) recordings.** They have no checkpoint, so they are never resumed. On a recovery launch the watch ends the leftover system workout session (not saved to Apple Health: it is ended without `finishWorkout`, as the previous build did at the next start) and closes the folder as `recovered: true`, so the files are kept and sent without the "Keep" tap that earlier builds needed.

`events.csv` also gets a `thermal` row at the start and on every change, detail `nominal`, `fair`, `serious` or `critical` (`ProcessInfo.thermalState`).

## Labels
`activity` is one of `run, transition, skierg, sled_push, sled_pull, burpee_broad_jump, row, farmers_carry, sandbag_lunges, wall_balls, rest`.
`event` is `set` or `undo`. A `set` starts a label that lasts until the next `set`. An `undo` removes the most recent surviving `set`, so the label before it resumes from its own start (a mistaken tap gives its time back). A `set` equal to the current label is not logged.

## Cues
`event`: `issued` (once per cue), then `finished` or `cancelled` (the speech synthesizer's delegate), `timeout` (no finish within 15 s), `failed`, or `missed` (the athlete tapped "Didn't hear last cue").
`mode`: `speech` (speech is always attempted whatever the route reads; a failed audio session is noted in `detail`) or `haptic_only` (older sessions only). Every cue also plays a haptic.
`audio_mode`: `A` = `.playback`/`.spokenAudio` with ducking, session activated before each cue; `B` = `.longFormAudio` route policy, activated once at session start and kept active. Chosen on the watch home screen; also in `manifest.json`.
`headphones`: `1` if any output port at that moment was Bluetooth A2DP/HFP/LE, wired headphones or AirPlay. `outputs` is `PortType/PortName` joined by `;`.
A cue counts as delivered only if it was `speech` to headphones, `finished`, and not `missed`. All issued cues are in the denominator. `finished` means the synthesizer finished, not that a person heard it: the "Didn't hear" button is the human check.

## Rates
`raw_hz` is the sensor delivery rate in the window, from sensor timestamps. `stored_hz` is what reached the file after decimation. `tools/m1_report.py` reports the stored rate (median samples per whole second) because that is the data the detector will get.

## Transfer
The watch sends each file with `WCSession.transferFile`, metadata `{session, name, bytes, total}`. The phone moves it to `Documents/Sessions/<session>/`, and when `total` files have arrived at the announced sizes it sends `{ack: <session>}` back with `transferUserInfo`. The watch keeps a session until it has seen that ack and the athlete chooses "Delete sent".

## Expected motion rates (a recent Series watch, unverified until a device run)
The test watch is a recent Series model. Minimum OS is watchOS 10, the first release with `CMBatchedSensorManager`; nothing lower works for the main path.

| Path | Accelerometer | Device motion | Notes |
|---|---|---|---|
| `CMBatchedSensorManager` (main) | up to 800 Hz raw | up to 200 Hz raw | Apple documents these rates for recent watches; needs a running workout session. Expected on a recent Series watch, not yet confirmed. |
| `CMMotionManager` (fallback) | asked for 100 Hz | asked for 100 Hz | Used if batched is unsupported or its stream errors. The achieved rate may be lower; it is logged in `rates.csv`. |

Stored rate is the raw rate decimated to at most `storeHz`, settable on the watch home screen (25, 50, 100 or 200 Hz; default 100). Device motion cannot store above its raw rate, so 200 only helps if the sensor delivers it. The 50 Hz pass mark needs `storeHz` >= 50.

## Battery-conscious choices
- Samples are decimated, then written in per-batch groups to a 256 KB in-memory buffer; the file is fsynced once a minute (and the buffer drained when it fills), not per sample.
- No network. No GPS (indoor workout). The elapsed clock drops seconds when the display is dimmed.
- Cue interval (default 45 s) and motion store rate are settable.
- Battery is logged every 60 s.

Training load (`TrainingLoad.swift`): on an `early` session the split with the latest `startMs` counts as quit. Its time still counts toward load, but it adds no sim km or station metres, and an early full sim is not counted as a full sim.
