# Session protocol

Follow this for every recorded session; it keeps the pass marks about the watch, not about the setup.

## Before
- Watch fully charged (the battery mark assumes a start near 100%). Phone nearby but not needed.
- **AirPods connected to the watch, not playing from the phone.** If music plays from the phone the AirPods are attached to the phone and the cues may not route. Pick the music source first: none, or music hosted on the watch. Write it in the notes below.
- No other workout app running (it ends the recorder's workout session; the recorder alarms if that happens).
- Earlier sessions show "on phone" in the watch's Sessions list. The recorder does not transfer while recording, but a pending transfer from a previous session should finish first.
- On the home screen set the athlete code (A1, A2, ...; never a name), the wrist, the cue interval and the audio mode (A or B). Run a 10-minute desk test with 10 s cues in each mode before gym day and check `cues.csv`: `mode=speech`, outputs containing `BluetoothA2DPOutput`, and by ear.

### Desk test additions
- Mode B with the AirPods **not** connected: starting a session may show the system audio route picker and wait. Note what happens if you dismiss it (the log should say "NOT activated") and whether cues then speak at all.
- Mode B, then switch the AirPods off mid-session and on again: `events.csv` should show "headphones lost; will re-activate when a headphone output reappears", then a route change and "reactivating: headphones back" once they return, and cues should resume. While they are off, cues are still attempted (on the speaker or not at all) and the recorder does not pop the route picker.
- Force-quit the app mid-session, relaunch, tap "Keep and send", start a new session, and confirm it records (rates.csv rows every minute, no "Could not start").
- Compare `headphones` in `cues.csv` with what you heard, cue by cue, in each mode. If the report's "finished and not flagged, any route" line is well above the main figure, the route read is unreliable.

## Coached session
- Build the plan on the phone (Plan tab), tap Send to watch, then open the watch app: the Ready screen shows the session, the target and the athlete chip. START begins the workout session, the recorder and the coach together.
- NEXT (or a double pinch, if the watch supports it) moves to the next phase. A mistaken NEXT inside 3 s of the last one is ignored. Long press for Undo or End.
- NOT HEARD sits beside NEXT on every screen. The coach only speaks one cue per 20 s and never over a cue.
- The wall-ball count is a beta estimate: correct it with + and -.
- After the session the Summary tab shows the insight, table, chart and share card once the files have reached the phone.

## During
- Tap the activity when you start it. Hold the top of the screen to undo a mistaken tap.
- Tap DIDN'T HEAR (pinned at the top) when you miss a cue, before the next cue. Without taps, "delivered" only means the speech synthesizer finished, not that it was heard.
- A red RECORDING AT RISK banner with repeated haptics means the workout session or a motion stream died. Stop, then start a new session.

## After
- Tap End session. The files move to the phone in the background; wait for "on phone" before deleting from the watch.
- Note how many cues you heard roughly, which music source was used, and anything odd.
- Run `python3 tools/m1_report.py <session-folder> ...` on the exported folders.
