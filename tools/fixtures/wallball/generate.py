#!/usr/bin/env python3
"""Generates the synthetic wall-ball golden signals (<name>.csv: t,magnitude) and expected.json.

SYNTHETIC: noise plus half-sine bursts, not recordings. They pin the counter's behaviour so the Swift and Python
implementations cannot drift apart; they say nothing about how real wall balls look on a wrist.

  generate.py          rewrite the CSVs (expected.json is only rewritten with --expected)
  generate.py --check  fail if the committed CSVs differ from what this script produces

expected.json is the counter's output at the time of writing, reviewed by hand against the intent in `note`.
"""
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))
from wallball_replay import WallBallCounter  # noqa: E402

HZ = 100


def signal(bursts, amp, duration, catch_delay=None, seed=42):
    """100 Hz magnitude (g): small noise plus a 0.3 s half-sine of `amp` at each burst time.
    bursts is a list of times, or (time, amp) pairs."""
    out = []
    for i in range(int(duration * HZ)):
        t = i / HZ
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        m = 0.05 + (seed >> 33) / (1 << 31) * 0.08
        for b in bursts:
            b, a = b if isinstance(b, tuple) else (b, amp)
            for off in ([0.0, catch_delay] if catch_delay else [0.0]):
                p = t - (b + off)
                if 0 <= p < 0.3:
                    m += a * math.sin(math.pi * p / 0.3)
        out.append((f"{t:.2f}", f"{m:.5f}"))
    return out


def every(interval, count, start=5.0):
    return [start + k * interval for k in range(count)]


SCENARIOS = {
    "steady": ("10 reps every 3 s", signal(every(3, 10), 1.5, 36)),
    "jog_in": ("arm swing every 0.5 s for 8 s, then 6 reps",
               signal(every(0.5, 16, 1.0) + every(3, 6, 13.0), 1.5, 34)),
    "sets_with_rests": ("5 reps, 14 s rest, 5 reps",
                        signal(every(3, 5) + every(3, 5, 31.0), 1.5, 50)),
    "fast_reps": ("12 reps every 1.9 s", signal(every(1.9, 12), 1.5, 32)),
    "catch_peaks": ("10 throws every 3 s, each with a catch 1.2 s later",
                    signal(every(3, 10), 1.5, 36, catch_delay=1.2)),
    "pickup_bump": ("big ball-pickup bump at 2 s (inside the ignored first 4 s), then 8 reps",
                    signal([(2.0, 3.5)] + every(3, 8, 7.0), 1.5, 36)),
}


def run(rows):
    c = WallBallCounter()
    for t, m in rows:
        c.add(float(t), float(m))
    return c


def expected():
    out = {}
    for name, (note, rows) in SCENARIOS.items():
        c = run(rows)
        out[name] = {"note": note, "count": c.count, "confidence": c.confidence,
                     "repTimes": [round(t, 2) for t in c.rep_times]}
    return out


def csv_text(rows):
    return "t,magnitude\n" + "".join(f"{t},{m}\n" for t, m in rows)


def main(argv):
    if "--check" in argv:
        bad = [n for n, (_, rows) in SCENARIOS.items()
               if not (HERE / f"{n}.csv").exists() or (HERE / f"{n}.csv").read_text() != csv_text(rows)]
        print("stale: " + ", ".join(bad) if bad else "fixtures current")
        return 1 if bad else 0
    for n, (_, rows) in SCENARIOS.items():
        (HERE / f"{n}.csv").write_text(csv_text(rows))
    if "--expected" in argv:
        (HERE / "expected.json").write_text(json.dumps(expected(), indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
