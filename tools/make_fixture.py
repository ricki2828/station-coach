#!/usr/bin/env python3
"""Regenerates tools/fixtures/session-fixture, a tiny synthetic session in the FORMAT.md layout.

The values are chosen so tools/tests/test_m1_report.py can assert exact numbers:
  100 min session, battery 100% falling 0.5%/min, 20 cues (18 delivered, 1 haptic-only, 1 flagged missed),
  accel + motion at 100 Hz for 20 s, one mistaken 'rest' label undone.
"""
import json
from pathlib import Path

T0 = 1_790_000_000_000  # epoch ms
MIN = 60_000
OUT = Path(__file__).parent / "fixtures" / "session-fixture"

# (start minute, activity); the 'rest' at 58 is undone at 58.5, so wall_balls runs to minute 60.
SCHEDULE = [
    (0, "run"), (8, "transition"), (9, "skierg"), (14, "run"), (22, "transition"),
    (23, "sled_push"), (26, "sled_pull"), (29, "burpee_broad_jump"), (34, "row"),
    (40, "farmers_carry"), (44, "sandbag_lunges"), (50, "wall_balls"), (58, "rest"), (60, "run"),
]


def write(name, header, rows):
    (OUT / name).write_text(header + "\n" + "".join(r + "\n" for r in rows))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "manifest.json").write_text(json.dumps({
        "formatVersion": 1, "sessionId": "fixture", "startedAtEpochMs": T0,
        "endedAtEpochMs": T0 + 100 * MIN, "device": "Synthetic", "osVersion": "watchOS 10",
        "appVersion": "0.1.0", "workoutActivityType": "crossTraining",
        "motionApi": "CMBatchedSensorManager", "requestedHz": 800, "storeHz": 100,
        "cueIntervalSec": 45,
    }, indent=2, sort_keys=True) + "\n")

    labels = []
    for minute, act in SCHEDULE:
        labels.append(f"{T0 + minute * MIN},set,{act}")
        if act == "rest":
            labels.append(f"{T0 + 58 * MIN + MIN // 2},undo,rest")
    write("labels.csv", "epoch_ms,event,activity", labels)

    cues = []
    for i in range(1, 21):
        t = T0 + i * 45_000
        if i == 5:
            cues.append(f"{t},{i},issued,haptic_only,0,BuiltInSpeaker/Watch Speaker,Keep your rhythm.,no headphones")
            continue
        cues.append(f"{t},{i},issued,speech,1,BluetoothA2DPOutput/AirPods,Keep your rhythm.,")
        cues.append(f"{t + 2500},{i},finished,speech,1,BluetoothA2DPOutput/AirPods,Keep your rhythm.,")
        if i == 9:
            cues.append(f"{t + 6000},{i},missed,speech,1,BluetoothA2DPOutput/AirPods,Keep your rhythm.,")
    write("cues.csv", "epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail", cues)

    write("battery.csv", "epoch_ms,level,state",
          [f"{T0 + m * MIN},{1 - 0.005 * m:.2f},unplugged" for m in range(0, 101)])
    write("hr.csv", "epoch_ms,bpm", [f"{T0 + s * 5000},{120 + s % 40}" for s in range(0, 40)])
    base_us = T0 * 1000
    write("accel.csv", "epoch_us,x,y,z",
          [f"{base_us + i * 10_000},0.01000,-0.02000,0.98000" for i in range(2000)])
    write("motion.csv", "epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z",
          [f"{base_us + i * 10_000},0.01000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,-1.00000"
           for i in range(2000)])
    write("rates.csv", "epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz",
          [f"{T0 + 60_000},accel,48000,800.0,6000,100.0", f"{T0 + 60_000},motion,12000,200.0,6000,100.0"])
    write("events.csv", "epoch_ms,kind,detail", [f"{T0},session_start,fixture"])


if __name__ == "__main__":
    main()
