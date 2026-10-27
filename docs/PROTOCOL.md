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
- Force-quit the app mid-session, relaunch, tap "Keep and send", start a new session, and confirm it records (rates.csv rows every minute, no "Could not start"). `tools/desk_check.py` reads this off the new session's folder.
- **Crash recovery, coached session.** Force-quit mid-coached-session and relaunch: the session resumes at the same step; if it can't, History shows it as ended early. Either way the splits so far must survive. Note which happened, and check the folder has `coach.json` (and `events.csv` `recovered_resume` if it resumed). Not run on a device yet.
- Compare `headphones` in `cues.csv` with what you heard, cue by cue, in each mode. If the report's "finished and not flagged, any route" line is well above the main figure, the route read is unreliable.

## Coached session
- Build the plan on the phone (Plan tab), tap Send to watch, then open the watch app: the Ready screen shows the session, the target and the athlete chip. START begins the workout session, the recorder and the coach together.
- NEXT (or a double pinch, if the watch supports it) moves to the next phase. A mistaken NEXT inside 3 s of the last one is ignored. Press and hold for 1.5 s for Undo or End. The last step's button is HOLD TO FINISH (1 s).
- NOT HEARD sits beside NEXT on every screen. The coach only speaks one cue per 20 s and never over a cue.
- Tap NEXT when you pick up the ball, not while you are still jogging to the wall: the counter skips the first 4 s and any arm-swing rhythm, but it cannot tell a long walk from reps.
- The wall-ball count is a beta estimate: correct it with + and -.
- After the session the Summary tab shows the insight, table, chart and share card once the files have reached the phone.

### Desk test: wall balls
- Do 20 real wall balls after a 15 s jog-in (NEXT tapped as you start jogging) and compare the watch's count with 20. Log the counter's rep times in `coach.json`, and note any phantom reps from the jog or from picking the ball up between sets.
- Hold HOLD TO FINISH for about 1 s and expect the finish screen, not the Undo/End menu. The menu needs a 1.5 s long press elsewhere on the screen; if it opens first, say so.

## Before gym day: coached-session checklist
Do these on the watch, in order, before the first real session. Note what you see; none of them has been run on a device yet.
1. **Finish and undo.** Hold HOLD TO FINISH for 1 s on the last step: it should finish, not open the Undo/End menu. Then tap UNDO inside the 10 s window and check the wall-ball count carries on from where it was (the count and the +/- correction are kept, and sets already passed are not announced again).
2. **Wall balls after a jog-in.** Do 20 real wall balls after a 15 s jog-in (NEXT tapped as you start jogging). Compare the watch's count, and any "Set done" it spoke, with the true count. Note phantom reps from the jog or from picking the ball up, and any set cue spoken at the wrong count.
3. **Corners and clock.** On the wrist, check the screens against the snapshot mask: nothing under the clock, the delta band and the HR chip not clipped, and the bottom NEXT / NOT HEARD buttons not cut by the rounded corners. The mask in the PNGs (44 pt corners, 24 pt top inset) is an estimate.
4. **Finish cue logged.** After a coached session, `gymday.py` checks that the finish cue has both an `issued` and a `finished` row in `cues.csv`. If it only has `issued`, the writer closed before the speech ended.

## During
- Tap the activity when you start it. Hold the top of the screen to undo a mistaken tap.
- Tap DIDN'T HEAR (pinned at the top) when you miss a cue, before the next cue. Without taps, "delivered" only means the speech synthesizer finished, not that it was heard.
- A red RECORDING AT RISK banner with repeated haptics means the workout session or a motion stream died. Stop, then start a new session.

## After
- Tap End session. The files move to the phone in the background; wait for "on phone" before deleting from the watch.
- Note how many cues you heard roughly, which music source was used, and anything odd.
- Export each session from the phone (History > Raw files) and get the zips onto the host.
- `python3 tools/ingest.py <zip|folder> ... --into ~/station-coach-data` files and validates them; it says what it skipped and why.
- `python3 tools/gymday.py ~/station-coach-data --wb-truth <session>=20 --md verdict.md` gives the M1 verdict per pass mark. `docs/GYMDAY.md` has the rules.
- `python3 tools/desk_check.py <session-folder>` automates the desk-test reads above. `tools/m1_report.py <session-folder> ...` still prints the full detail for single sessions.
