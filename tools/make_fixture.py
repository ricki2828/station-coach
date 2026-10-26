#!/usr/bin/env python3
"""Regenerates tools/fixtures/session-fixture, a small synthetic session in the FORMAT.md layout.

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


def write(name, header, rows):
    (OUT / name).write_text(header + "\n" + "".join(r + "\n" for r in rows))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "manifest.json").write_text(json.dumps({
        "formatVersion": 1, "sessionId": "fixture", "startedAtEpochMs": T0,
        "endedAtEpochMs": T0 + DURATION_S * SEC, "device": "Synthetic", "osVersion": "watchOS 10",
        "appVersion": "0.1.0", "workoutActivityType": "crossTraining",
        "motionApi": "CMBatchedSensorManager", "requestedHz": 800, "storeHz": 100,
        "cueIntervalSec": 10, "audioMode": "A", "athlete": "A1", "wrist": "left",
    }, indent=2, sort_keys=True) + "\n")

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


if __name__ == "__main__":
    main()
