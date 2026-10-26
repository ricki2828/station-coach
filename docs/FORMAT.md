# Session format, version 1

One folder per session: `<UTC start as yyyyMMdd'T'HHmmss'Z'>-<6 hex>`. Everything is UTF-8 CSV with a header row, appended while recording and flushed (fsync) every 60 s, so a crash or flat battery keeps all but the last minute. All timestamps are Unix epoch time: `epoch_ms` is milliseconds, `epoch_us` is microseconds. Motion timestamps come from the sensor (boot-relative) shifted to epoch with the offset sampled at app start.

| File | Columns | Written |
|---|---|---|
| `manifest.json` | `formatVersion`, `sessionId`, `startedAtEpochMs`, `endedAtEpochMs`, `device`, `osVersion`, `appVersion`, `workoutActivityType`, `motionApi`, `requestedHz`, `storeHz`, `cueIntervalSec`, `audioMode`, `athlete` (code such as A1, never a name), `wrist` (`left`/`right`), `recovered` (true if closed after an unexpected stop), `labelSource` (`athlete_taps` or `coach`), `transitionLabelSeconds` (coach sessions: a run after a station is labelled `transition` for its first this-many seconds, a time rule and not an observation), `files` | at start, rewritten at finish (`endedAtEpochMs` and `files` are absent from a session that never finished) |
| `labels.csv` | `epoch_ms,event,activity` | on each tap / undo |
| `cues.csv` | `epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail,audio_mode` | per cue event |
| `battery.csv` | `epoch_ms,level,state` | every 60 s |
| `hr.csv` | `epoch_ms,bpm` | on each HealthKit heart-rate sample |
| `accel.csv` | `epoch_us,x,y,z` (g) | decimated to at most `storeHz` (100) |
| `motion.csv` | `epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z` (user acceleration g, rotation rate rad/s, gravity g) | decimated to at most `storeHz` |
| `rates.csv` | `epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz` | every 60 s, one row per stream, for that window |
| `events.csv` | `epoch_ms,kind,detail` | session start/end, motion API, workout state, audio route changes, errors |

## Coached sessions
A session started from the coach (plan from the phone) is the same folder plus `coach.json`, written at the end by the watch:
`plan` (division, session type, race target, `steps` with per-step targets and wall-ball set structure, `transitionSeconds`), `splits` (`stepIndex`, `startMs`, `endMs`; a step never started has no split, a step not finished has no `endMs`), `early`, `repTimesMs` (heuristic wall-ball rep times, epoch ms), `repCorrection` (net manual +/-), `startedAtEpochMs`, `endedAtEpochMs`.
In a coached session the cue timer is off, so `manifest.cueIntervalSec` is `0` and the report does not expect periodic cues; cues come from the coach and are logged in `cues.csv` as before. Coach phase changes write `labels.csv` automatically (and `rest` once the session is finished, until the files close): `run`, `transition` (the first `transitionSeconds` of a run that follows a station) and the station activities.
The wall-ball rep count is a beta heuristic (peaks in wrist acceleration magnitude) and counts down on the watch; the athlete corrects it with +/-.

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
