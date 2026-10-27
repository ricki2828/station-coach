#!/usr/bin/env python3
"""Regenerates tools/fixtures/session-fixture and tools/fixtures/coached-fixture, small synthetic sessions
in the FORMAT.md layout (the second is a coached session with coach.json; see coached() below).

session-fixture:

120 s long, cue interval 10 s, so tests can assert exact numbers:
  12 cues (10 delivered, 1 haptic-only, 1 flagged missed), accel + motion at 100 Hz for the whole
  session, battery every 60 s, every activity labelled for 10 s (wall balls 20 s, run 20 s) with
  one mistaken 'rest' label undone.
"""
import json
from pathlib import Path

T0 = 1_790_000_000_000  # epoch ms
SEC = 1000
DURATION_S = 120
OUT = Path(__file__).parent / "fixtures" / "session-fixture"

# (start second, activity). The 'rest' at 100 s is undone at 103 s, so wall_balls runs to 110 s.
SCHEDULE = [
    (0, "run"), (10, "transition"), (20, "skierg"), (30, "sled_push"), (40, "sled_pull"),
    (50, "burpee_broad_jump"), (60, "row"), (70, "farmers_carry"), (80, "sandbag_lunges"),
    (90, "wall_balls"), (100, "rest"), (110, "run"),
]


def write(name, header, rows, out=None):
    ((out or OUT) / name).write_text(header + "\n" + "".join(r + "\n" for r in rows))


def write_manifest(out, manifest):
    """Like the watch: `files` lists every file in the folder, manifest.json included."""
    names = sorted([p.name for p in out.iterdir() if p.name != "manifest.json"] + ["manifest.json"])
    (out / "manifest.json").write_text(json.dumps({**manifest, "files": names}, indent=2, sort_keys=True) + "\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = ({
        "formatVersion": 1, "sessionId": "fixture", "startedAtEpochMs": T0,
        "endedAtEpochMs": T0 + DURATION_S * SEC, "device": "Synthetic", "osVersion": "watchOS 10",
        "appVersion": "0.1.0", "workoutActivityType": "crossTraining",
        "motionApi": "CMBatchedSensorManager", "requestedHz": 800, "storeHz": 100,
        "cueIntervalSec": 10, "audioMode": "A", "athlete": "A1", "wrist": "left",
    })

    labels = []
    for sec, act in SCHEDULE:
        labels.append(f"{T0 + sec * SEC},set,{act}")
        if act == "rest":
            labels.append(f"{T0 + 103 * SEC},undo,rest")
    write("labels.csv", "epoch_ms,event,activity", labels)

    cues = []
    out = "BluetoothA2DPOutput/AirPods"
    for i in range(1, 13):
        t = T0 + (i * 10 - 5) * SEC
        if i == 5:
            cues.append(f"{t},{i},issued,haptic_only,0,BuiltInSpeaker/Watch Speaker,Keep your rhythm.,no headphones,A")
            continue
        cues.append(f"{t},{i},issued,speech,1,{out},Keep your rhythm.,,A")
        cues.append(f"{t + 2500},{i},finished,speech,1,{out},Keep your rhythm.,,A")
        if i == 9:
            cues.append(f"{t + 6000},{i},missed,speech,1,{out},Keep your rhythm.,,A")
    write("cues.csv", "epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail,audio_mode", cues)

    write("battery.csv", "epoch_ms,level,state",
          [f"{T0 + m * 60 * SEC},{1 - 0.005 * m:.2f},unplugged" for m in range(0, 3)])
    write("hr.csv", "epoch_ms,bpm", [f"{T0 + s * 5 * SEC},{120 + s % 40}" for s in range(0, 24)])
    base_us = T0 * 1000
    n = DURATION_S * 100
    write("accel.csv", "epoch_us,x,y,z",
          [f"{base_us + i * 10_000},0.01000,-0.02000,0.98000" for i in range(n)])
    write("motion.csv", "epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z",
          [f"{base_us + i * 10_000},0.01000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,-1.00000"
           for i in range(n)])
    write("rates.csv", "epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz",
          [f"{T0 + 60 * SEC},accel,48000,800.0,6000,100.0", f"{T0 + 60 * SEC},motion,12000,200.0,6000,100.0"])
    write("events.csv", "epoch_ms,kind,detail", [f"{T0},session_start,fixture"])
    write_manifest(OUT, manifest)
    coached()


# --- coached-fixture: 188 s, cues from the coach (cueIntervalSec 0), 50 Hz, a full pass of every check ---
COACHED = Path(__file__).parent / "fixtures" / "coached-fixture"
STATIONS = ["skierg", "sled_push", "sled_pull", "burpee_broad_jump", "row", "farmers_carry", "sandbag_lunges", "wall_balls"]
RUN_S, STATION_S, WALL_BALL_S = 8, 12, 40
TRANSITION_S = 2
WALL_BALL_REPS = 20


def coached():
    COACHED.mkdir(parents=True, exist_ok=True)
    steps, splits, labels, cues = [], [], [], []
    t = 0
    out = "BluetoothA2DPOutput/AirPods"

    def cue(i, at_s, phrase, dur_ms=2500):
        cues.append(f"{T0 + at_s * SEC},{i},issued,speech,1,{out},{phrase},,A")
        cues.append(f"{T0 + at_s * SEC + dur_ms},{i},finished,speech,1,{out},{phrase},,A")

    for i in range(8):
        for activity, length, run_number in (("run", RUN_S, i + 1), (STATIONS[i], WALL_BALL_S if STATIONS[i] == "wall_balls" else STATION_S, None)):
            idx = len(steps)
            wall = activity == "wall_balls"
            steps.append({"activity": activity, "index": idx, "runNumber": run_number, "targetSeconds": length,
                          "reps": WALL_BALL_REPS if wall else None, "sets": [10, 10] if wall else []})
            splits.append({"stepIndex": idx, "startMs": T0 + t * SEC, "endMs": T0 + (t + length) * SEC})
            if activity == "run" and i > 0:
                labels.append(f"{T0 + t * SEC},set,transition")
                labels.append(f"{T0 + (t + TRANSITION_S) * SEC},set,run")
            else:
                labels.append(f"{T0 + t * SEC},set,{activity}")
            cue(idx + 1, t, f"Step {idx + 1}.")
            t += length
    total = t
    cue(len(steps) + 1, total, "3:08. On target.")  # the finish line is the last cue
    labels.append(f"{T0 + total * SEC},set,rest")
    wb_start = T0 + (total - WALL_BALL_S) * SEC
    reps = [wb_start + (5 + int(k * 1.5 + (k // 10) * 5)) * SEC for k in range(WALL_BALL_REPS)]
    (COACHED / "coach.json").write_text(json.dumps({
        "plan": {"division": "open_men", "type": "full_sim", "raceTargetSeconds": total, "steps": steps, "transitionSeconds": TRANSITION_S},
        "splits": splits, "early": False, "repTimesMs": reps, "repCorrection": 0, "noReps": [],
        "startedAtEpochMs": T0, "endedAtEpochMs": T0 + total * SEC,
    }, indent=2, sort_keys=True) + "\n")
    write("labels.csv", "epoch_ms,event,activity", labels, COACHED)
    write("cues.csv", "epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail,audio_mode", cues, COACHED)
    write("battery.csv", "epoch_ms,level,state", [f"{T0 + m * 60 * SEC},{1 - 0.005 * m:.2f},unplugged" for m in range(0, total // 60 + 1)], COACHED)
    write("hr.csv", "epoch_ms,bpm", [f"{T0 + s * 5 * SEC},{120 + s % 40}" for s in range(0, total // 5)], COACHED)
    n = total * 50
    base_us = T0 * 1000
    write("accel.csv", "epoch_us,x,y,z", [f"{base_us + i * 20_000},0.01000,-0.02000,0.98000" for i in range(n)], COACHED)
    write("motion.csv", "epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z",
          [f"{base_us + i * 20_000},0.01000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,-1.00000" for i in range(n)], COACHED)
    write("rates.csv", "epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz",
          [f"{T0 + m * 60 * SEC},{s},{r},{rz},3000,50.0" for m in range(1, total // 60 + 1)
           for s, r, rz in (("accel", 48000, "800.0"), ("motion", 12000, "200.0"))], COACHED)
    write("events.csv", "epoch_ms,kind,detail",
          [f"{T0},session_start,coached-fixture", f"{T0},thermal,nominal", f"{T0 + 100 * SEC},thermal,fair",
           f"{T0 + 60 * SEC},audio_mode,headphones lost; will re-activate when a headphone output reappears",
           f"{T0 + 70 * SEC},audio_mode,reactivating: headphones back"], COACHED)
    write_manifest(COACHED, {
        "formatVersion": 1, "sessionId": "coached-fixture", "startedAtEpochMs": T0, "endedAtEpochMs": T0 + total * SEC,
        "device": "Synthetic", "osVersion": "watchOS 10", "appVersion": "0.1.0", "workoutActivityType": "crossTraining",
        "motionApi": "CMBatchedSensorManager", "requestedHz": 800, "storeHz": 50, "cueIntervalSec": 0, "audioMode": "A",
        "athlete": "A1", "wrist": "left", "labelSource": "coach", "transitionLabelSeconds": TRANSITION_S,
    })


if __name__ == "__main__":
    main()
