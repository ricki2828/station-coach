#!/usr/bin/env python3
"""Replay a recorded session through the wall-ball rep counter, on the host, without Swift.

  wallball_replay.py <session-folder>

Prints, for each wall-ball step in coach.json, the reps this port counts in the step's window beside the watch's
own `repTimesMs` and the corrected count. `WallBallCounter` is a line-for-line port of
Packages/CoachKit/Sources/CoachKit/WallBallCounter.swift: change one and you change the other. The shared golden
fixtures in tools/fixtures/wallball/ are asserted by this port's test and by WallBallGoldenTests.swift, so drift
on either side fails CI.

What it is and is not:
- It replays the STORED samples (motion.csv: components at 5 decimals, epoch_us truncated), not the full-precision
  live feed, so expect rare differences of one rep or one ms from the watch's own count. It is not exact on real data.
- The watch is fed only while a wall-ball step is current. If the athlete advanced past wall balls by mistake and
  undid back, the counter was paused in between and missed those samples. The replay reconstructs that gap from
  labels.csv and skips it; without labels.csv it cannot, and says so.
- Batched sensor delivery means the live counter can see samples up to about one batch before the split start and miss
  some just before its end. The replay uses the exact split window, so a rep near the 4 s mark or the step end can differ.
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
    SMOOTH_KEEP = 0.8
    SMOOTH_NEW = 0.2  # not 1 - SMOOTH_KEEP: that is 0.19999999999999996, and Swift multiplies by the literal 0.2
    ENVELOPE_DECAY = 0.9995
    ENVELOPE_FRACTION = 0.5
    PEAK_DEDUPE = 0.25
    CONF_RECENT = 6
    CONF_MAX_CV = 0.4

    def __init__(self, min_interval=None, ignore_first=None):
        if min_interval is None:
            min_interval = self.DEFAULT_MIN_INTERVAL
        if ignore_first is None:
            ignore_first = self.DEFAULT_IGNORE_FIRST
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
        s = magnitude if self._smooth is None else self._smooth * self.SMOOTH_KEEP + magnitude * self.SMOOTH_NEW
        self._smooth = s
        self._envelope = max(s, self._envelope * self.ENVELOPE_DECAY)
        try:
            if self._samples < 2:
                return False
            threshold = max(self.MIN_THRESHOLD, self.ENVELOPE_FRACTION * self._envelope)
            is_peak = self._prev_s > self._prev_prev_s and self._prev_s >= s and self._prev_s > threshold
            prev_t = self._prev_t
            if is_peak:
                # Noise on the top of one burst can give two maxima a few samples apart: that is one swing.
                if not self._recent_peaks or prev_t - self._recent_peaks[-1] >= self.PEAK_DEDUPE:
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
        recent = self.rep_times[-self.CONF_RECENT:]
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
        return "high" if mean > 0 and math.sqrt(variance) / mean <= self.CONF_MAX_CV else "low"


def rep_ms(t):
    """Swift's Int64((t * 1000).rounded()): half away from zero."""
    x = t * 1000
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


class ReplayError(Exception):
    """A session folder that cannot be replayed (message is for the user)."""


def _num(row, key):
    v = row.get(key)
    if v is None or v == "":
        raise ValueError(key)
    return float(v)


def count_reps(motion_csv, start_ms, end_ms, skip=(), warnings=None):
    """Rep times (epoch ms) the counter finds in motion.csv samples with start_ms <= time <= end_ms.

    Never raises on data problems: a missing or unreadable file gives [], and rows that are torn (a crash or flat
    battery loses the last partial line) or non-numeric are skipped. Pass a list as `warnings` to learn about them;
    without it a missing file is indistinguishable from "no reps". `skip` is a list of (from_ms, to_ms) intervals
    whose samples are not fed (the counter was paused on the watch).
    """
    warn = warnings if warnings is not None else []
    c = WallBallCounter()
    bad = 0
    try:
        with open(motion_csv, newline="") as f:
            for row in csv.DictReader(f):
                try:
                    if None in row or any(v is None or v == "" for v in row.values()):
                        raise ValueError("torn row")
                    t = _num(row, "epoch_us") / 1e6
                    x, y, z = _num(row, "ua_x"), _num(row, "ua_y"), _num(row, "ua_z")
                except (ValueError, KeyError, TypeError):
                    bad += 1
                    continue
                if not 1e9 < t < 1e11:  # a torn row glued to the next can leave a wild timestamp
                    bad += 1
                    continue
                ms = t * 1000
                if ms < start_ms or ms > end_ms:
                    continue  # no early exit: one wild row must not end the replay
                if any(a <= ms < b for a, b in skip):
                    continue
                c.add(t, math.sqrt(x * x + y * y + z * z))
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        warn.append(f"cannot read {motion_csv}: {e.__class__.__name__}")
        return []
    if bad:
        warn.append(f"skipped {bad} torn or non-numeric row(s) in {Path(motion_csv).name}")
    return [rep_ms(t) for t in c.rep_times]


def paused_intervals(labels_csv, start_ms, end_ms):
    """(intervals, known): spans inside [start_ms, end_ms] where the label left wall_balls and came back (an
    advance then an undo), during which the watch's counter was paused. known is False without a readable labels.csv.
    A `set` pushes a label and an `undo` pops the last one, as in FORMAT.md."""
    try:
        with open(labels_csv, newline="") as f:
            rows = []
            for r in csv.DictReader(f):
                try:
                    rows.append((int(r["epoch_ms"]), r["event"], r["activity"]))
                except (ValueError, KeyError, TypeError):
                    continue
    except (OSError, UnicodeDecodeError, csv.Error):
        return [], False
    stack = []

    def apply(event, activity):
        if event == "set":
            stack.append(activity)
        elif event == "undo" and stack:
            stack.pop()

    for ms, event, activity in rows:
        if ms < start_ms:
            apply(event, activity)
    seen = bool(stack) and stack[-1] == "wall_balls"
    out, paused_from = [], None
    for ms, event, activity in rows:
        if ms < start_ms or ms > end_ms:
            continue
        apply(event, activity)
        on = bool(stack) and stack[-1] == "wall_balls"
        if on:
            if paused_from is not None:
                out.append((paused_from, ms))
                paused_from = None
            seen = True
        elif seen and paused_from is None:
            paused_from = ms
    return out, True


def resumes(events_csv, start_ms, end_ms):
    """Epoch ms of `recovered_resume` events in events.csv inside [start_ms, end_ms]. After one the watch counts with
    a fresh detector (new ignore window, envelope and peak history), which a continuous replay does not model."""
    out = []
    try:
        with open(events_csv, newline="") as f:
            for r in csv.DictReader(f):
                try:
                    ms = int(r["epoch_ms"])
                except (ValueError, KeyError, TypeError):
                    continue
                if r.get("kind") == "recovered_resume" and start_ms <= ms <= end_ms:
                    out.append(ms)
    except (OSError, UnicodeDecodeError, csv.Error):
        pass
    return out


def corrected_counts(coach, folder):
    """(valid_reps, no_reps) as the app derives them (CoachResult.validReps / noRepCount): the phone's
    phone-correction.json over coach.json, else repTimesMs + repCorrection - noReps, clamped at 0. A legacy bare-Int
    wallBallCorrection is the corrected total of throws."""
    no_reps = coach.get("noReps") or []
    corr = coach.get("wallBallCorrection")
    if isinstance(corr, bool):
        corr = None
    if isinstance(corr, int):
        corr = {"validReps": max(0, corr - len(no_reps)), "noReps": len(no_reps)}
    elif not isinstance(corr, dict):
        corr = None
    try:
        side = json.loads((Path(folder) / "phone-correction.json").read_text())
        if isinstance(side, dict) and isinstance(side.get("validReps"), int) and isinstance(side.get("noReps"), int):
            corr = {"validReps": min(max(side["validReps"], 0), 300), "noReps": min(max(side["noReps"], 0), 100)}
    except (OSError, ValueError):
        pass
    if corr is not None:
        return max(0, corr["validReps"]), max(0, corr["noReps"])
    valid = max(0, len(coach.get("repTimesMs", [])) + coach.get("repCorrection", 0) - len(no_reps))
    return valid, len(no_reps)


def replay(folder):
    folder = Path(folder)
    try:
        coach = json.loads((folder / "coach.json").read_text())
        steps = {s["index"]: s for s in coach["plan"]["steps"]}
        splits = coach["splits"]
    except FileNotFoundError:
        raise ReplayError(f"no coach.json in {folder} (a session that crashed has none until it is closed)")
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise ReplayError(f"coach.json in {folder} is unreadable ({e.__class__.__name__})")
    motion = folder / "motion.csv"
    if not motion.exists():
        raise ReplayError(f"no motion.csv in {folder}")
    watch_times = coach.get("repTimesMs", [])
    out = []
    for split in splits:
        step = steps.get(split.get("stepIndex"))
        if not step or step.get("activity") != "wall_balls" or split.get("skipped"):
            continue  # a skipped or moved attempt is not a wall-ball window
        start = split["startMs"]
        end = split.get("endMs") or coach.get("endedAtEpochMs") or float("inf")
        skip, known = paused_intervals(folder / "labels.csv", start, end)
        warnings = []
        if not known:
            warnings.append("no labels.csv: an advance-then-undo gap cannot be ruled out, counts may not be comparable")
        for ms in resumes(folder / "events.csv", start, end):
            warnings.append(f"recovered_resume at {ms}: the watch restarted its detector there, counts after it may "
                            "not be comparable")
        replayed = count_reps(motion, start, end, skip, warnings)
        watch = [t for t in watch_times if start <= t <= end]
        out.append({"stepIndex": split["stepIndex"], "startMs": start, "endMs": end, "replayed": replayed,
                    "watch": watch, "target": step.get("reps"), "paused": skip, "warnings": warnings})
    return coach, out


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    try:
        coach, steps = replay(argv[1])
    except ReplayError as e:
        print(f"error: {e}")
        return 1
    if not steps:
        print("no wall-ball step with a split in coach.json")
        return 1
    for s in steps:
        print(f"step {s['stepIndex']}: replayed {len(s['replayed'])} reps, watch counted {len(s['watch'])}"
              f" (plan {s['target']})")
        print(f"  replayed repTimesMs: {s['replayed']}")
        print(f"  watch    repTimesMs: {s['watch']}")
        for a, b in s["paused"]:
            print(f"  paused on the watch {a}..{b} (advance then undo): those samples were not replayed")
        for w in s["warnings"]:
            print(f"  warning: {w}")
    total_watch = sum(len(s["watch"]) for s in steps)
    total_replay = sum(len(s["replayed"]) for s in steps)
    valid, no_reps = corrected_counts(coach, argv[1])
    print(f"total: replayed {total_replay}, watch {total_watch}, corrected {valid} valid + {no_reps} no-rep"
          f" (repCorrection {coach.get('repCorrection', 0):+d})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
