# Session protocol

Follow this for every recorded session; it keeps the pass marks about the watch, not about the setup.

## Before
- Watch fully charged (the battery mark assumes a start near 100%). Phone nearby but not needed.
- **AirPods connected to the watch, not playing from the phone.** If music plays from the phone the AirPods are attached to the phone and the cues may not route. Pick the music source first: none, or music hosted on the watch. Write it in the notes below.
- No other workout app running (it ends the recorder's workout session; the recorder alarms if that happens).
- Earlier sessions show "on phone" in the watch's Sessions list. The recorder does not transfer while recording, but a pending transfer from a previous session should finish first.
- On the home screen set the athlete code (A1, A2, ...; never a name), the wrist, the cue interval and the audio mode (A or B). Run a 10-minute desk test with 10 s cues in each mode before gym day and check `cues.csv`: `mode=speech`, outputs containing `BluetoothA2DPOutput`, and by ear.

## During
- Tap the activity when you start it. Hold the top of the screen to undo a mistaken tap.
- Tap DIDN'T HEAR (pinned at the top) when you miss a cue, within 30 s of it. Without taps, "delivered" only means the speech synthesizer finished, not that it was heard.
- A red RECORDING AT RISK banner with repeated haptics means the workout session or a motion stream died. Stop, then start a new session.

## After
- Tap End session. The files move to the phone in the background; wait for "on phone" before deleting from the watch.
- Note how many cues you heard roughly, which music source was used, and anything odd.
- Run `python3 tools/m1_report.py <session-folder> ...` on the exported folders.
