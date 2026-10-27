#!/usr/bin/env python3
"""Replay a recorded session through the wall-ball rep counter, on the host, without Swift.

  wallball_replay.py <session-folder>

Prints, for each wall-ball step in coach.json, the reps this port counts in the step's window beside the watch's
own `repTimesMs` and the corrected count. `WallBallCounter` is a line-for-line port of
Packages/CoachKit/Sources/CoachKit/WallBallCounter.swift: change one and you change the other. The shared golden
fixtures in tools/fixtures/wallball/ are asserted by this port's test and by WallBallGoldenTests.swift, so drift
on either side fails CI.

Limits: each step is replayed from a fresh counter at its split start. The watch carries a count over when the
athlete undoes back into a step; the replay does not.
"""
import csv
import json
import math
import sys
from pathlib import Path

NEG_INF = float("-inf")


class WallBallCounter:
    DEFAULT_MIN_INTERVAL = 1.7
    DEFAULT_IGNORE_FIRST = 4.0
    MIN_THRESHOLD = 0.6
    REST_GAP = 8.0
    JOGGING_PEAKS = 4
    JOGGING_WINDOW = 2.0
    JOGGING_HOLD = 1.5

    def __init__(self, min_interval=DEFAULT_MIN_INTERVAL, ignore_first=DEFAULT_IGNORE_FIRST):
        self.count = 0
        self.rep_times = []
        self._smooth = None
        self._envelope = 0.0
        self._prev_t = 0.0
        self._prev_s = 0.0
        self._prev_prev_s = 0.0
        self._samples = 0
        self._last_peak_t = NEG_INF
        self._min_interval = min_interval
        self._ignore_first = ignore_first
        self._first_t = None
        self._recent_peaks = []
        self._jogging_until = NEG_INF

    def add(self, t, magnitude):
        """True when this sample completed a rep (the peak is detected one sample late)."""
        if self._first_t is None:
            self._first_t = t
        s = magnitude if self._smooth is None else self._smooth * 0.8 + magnitude * 0.2
        self._smooth = s
        self._envelope = max(s, self._envelope * 0.9995)
        try:
            if self._samples < 2:
                return False
            threshold = max(self.MIN_THRESHOLD, 0.5 * self._envelope)
            is_peak = self._prev_s > self._prev_prev_s and self._prev_s >= s and self._prev_s > threshold
            prev_t = self._prev_t
            if is_peak:
                # Noise on the top of one burst can give two maxima a few samples apart: that is one swing.
                if not self._recent_peaks or prev_t - self._recent_peaks[-1] >= 0.25:
                    self._recent_peaks.append(prev_t)
                self._recent_peaks = [p for p in self._recent_peaks if not prev_t - p > self.JOGGING_WINDOW]
                if len(self._recent_peaks) >= self.JOGGING_PEAKS:
                    self._jogging_until = prev_t + self.JOGGING_HOLD
            if (is_peak and prev_t > self._jogging_until
                    and prev_t - self._last_peak_t >= self._min_interval
                    and prev_t - self._first_t >= self._ignore_first):
                self._last_peak_t = prev_t
                self.count += 1
                self.rep_times.append(prev_t)
                return True
            return False
        finally:
            self._prev_prev_s = self._prev_s
            self._prev_s = s
            self._prev_t = t
            self._samples += 1

    @property
    def confidence(self):
        """'low' until 3 reps are in, and when the last intervals are uneven; else 'high'."""
        if len(self.rep_times) < 3:
            return "low"
        recent = self.rep_times[-6:]
        gaps = [b - a for a, b in zip(recent, recent[1:]) if b - a < self.REST_GAP]
        if len(gaps) < 2:
            return "high"
        mean = 0.0
        for g in gaps:
            mean += g
        mean /= len(gaps)
        variance = 0.0
        for g in gaps:
            variance += (g - mean) * (g - mean)
        variance /= len(gaps)
        return "high" if mean > 0 and math.sqrt(variance) / mean <= 0.4 else "low"


def rep_ms(t):
    """Swift's Int64((t * 1000).rounded()): half away from zero."""
    x = t * 1000
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def count_reps(motion_csv, start_ms, end_ms):
    """Rep times (epoch ms) the counter finds in motion.csv samples with start_ms <= time <= end_ms."""
    c = WallBallCounter()
    with open(motion_csv, newline="") as f:
        for row in csv.DictReader(f):
            t = int(row["epoch_us"]) / 1e6
            ms = t * 1000
            if ms < start_ms:
                continue
            if ms > end_ms:
                break
            x, y, z = float(row["ua_x"]), float(row["ua_y"]), float(row["ua_z"])
            c.add(t, math.sqrt(x * x + y * y + z * z))
    return [rep_ms(t) for t in c.rep_times]


def replay(folder):
    folder = Path(folder)
    coach = json.loads((folder / "coach.json").read_text())
    motion = folder / "motion.csv"
    steps = {s["index"]: s for s in coach["plan"]["steps"]}
    watch_times = coach.get("repTimesMs", [])
    out = []
    for split in coach["splits"]:
        step = steps.get(split["stepIndex"])
        if not step or step["activity"] != "wall_balls":
            continue
        start = split["startMs"]
        end = split.get("endMs") or coach.get("endedAtEpochMs") or float("inf")
        replayed = count_reps(motion, start, end)
        watch = [t for t in watch_times if start <= t <= end]
        out.append({"stepIndex": split["stepIndex"], "startMs": start, "endMs": end,
                    "replayed": replayed, "watch": watch, "target": step.get("reps")})
    return coach, out


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    coach, steps = replay(argv[1])
    if not steps:
        print("no wall-ball step with a split in coach.json")
        return 1
    correction = coach.get("repCorrection", 0)
    wbc = coach.get("wallBallCorrection")
    for s in steps:
        print(f"step {s['stepIndex']}: replayed {len(s['replayed'])} reps, watch counted {len(s['watch'])}"
              f" (plan {s['target']})")
        print(f"  replayed repTimesMs: {s['replayed']}")
        print(f"  watch    repTimesMs: {s['watch']}")
    total_watch = sum(len(s["watch"]) for s in steps)
    total_replay = sum(len(s["replayed"]) for s in steps)
    corrected = wbc["validReps"] if isinstance(wbc, dict) else total_watch + correction
    print(f"total: replayed {total_replay}, watch {total_watch}, corrected {corrected}"
          f" (repCorrection {correction:+d})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
