import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import wallball_replay as wb  # noqa: E402

GOLDEN = TOOLS / "fixtures" / "wallball"
EXPECTED = json.loads((GOLDEN / "expected.json").read_text())
T0 = 1_790_000_000_000  # epoch ms


def read_samples(name):
    with open(GOLDEN / f"{name}.csv", newline="") as f:
        return [(float(r["t"]), float(r["magnitude"])) for r in csv.DictReader(f)]


class GoldenTests(unittest.TestCase):
    """Same expected.json as Packages/CoachKit/Tests/CoachKitTests/WallBallGoldenTests.swift. Synthetic signals."""

    def test_golden(self):
        self.assertGreaterEqual(len(EXPECTED), 6)
        for name, want in EXPECTED.items():
            with self.subTest(name):
                c = wb.WallBallCounter()
                for t, m in read_samples(name):
                    c.add(t, m)
                self.assertEqual(c.count, want["count"])
                self.assertEqual(c.confidence, want["confidence"])
                self.assertEqual(len(c.rep_times), len(want["repTimes"]))
                for got, exp in zip(c.rep_times, want["repTimes"]):
                    self.assertAlmostEqual(got, exp, delta=0.005)

    def test_intent(self):
        # Hand-set expectations, independent of expected.json: guards against regenerating it from a broken port.
        self.assertEqual(EXPECTED["steady"]["count"], 10)
        self.assertEqual(EXPECTED["jog_in"]["count"], 6)
        self.assertEqual(EXPECTED["sets_with_rests"]["count"], 10)
        self.assertEqual(EXPECTED["fast_reps"]["count"], 12)
        self.assertEqual(EXPECTED["catch_peaks"]["count"], 10)
        self.assertEqual(EXPECTED["pickup_bump"]["count"], 8)

    def test_csvs_current(self):
        out = subprocess.run([sys.executable, str(GOLDEN / "generate.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout)


class ReplayTests(unittest.TestCase):
    def make_session(self, tmp, name="steady", offset_ms=T0):
        """motion.csv from a golden signal (magnitude on ua_x), and a coach.json with one wall-ball step."""
        samples = read_samples(name)
        with open(tmp / "motion.csv", "w") as f:
            f.write("epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z\n")
            for t, m in samples:
                f.write(f"{round((offset_ms / 1000 + t) * 1e6)},{m},0,0,0,0,0,0,0,-1\n")
        end = offset_ms + 40_000
        watch = [offset_ms + round(x * 1000) for x in EXPECTED[name]["repTimes"]][:-1]
        coach = {"plan": {"steps": [{"index": 0, "activity": "run", "reps": None},
                                    {"index": 1, "activity": "wall_balls", "reps": 10}]},
                 "splits": [{"stepIndex": 0, "startMs": offset_ms - 60_000, "endMs": offset_ms - 1},
                            {"stepIndex": 1, "startMs": offset_ms, "endMs": end}],
                 "repTimesMs": watch, "repCorrection": 1, "startedAtEpochMs": offset_ms - 60_000,
                 "endedAtEpochMs": end}
        (tmp / "coach.json").write_text(json.dumps(coach))
        return coach

    def test_count_reps_window(self):
        with tempfile.TemporaryDirectory() as d:
            self.make_session(Path(d))
            reps = wb.count_reps(Path(d) / "motion.csv", T0, T0 + 40_000)
            self.assertEqual(len(reps), 10)
            self.assertAlmostEqual(reps[0], T0 + 5190, delta=5)
            # A window that starts later sees a fresh counter: its own first 4 s are ignored.
            later = wb.count_reps(Path(d) / "motion.csv", T0 + 12_000, T0 + 40_000)
            self.assertEqual(len(later), 6)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            self.make_session(Path(d))
            out = subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), d],
                                 capture_output=True, text=True, check=True).stdout
            self.assertIn("step 1: replayed 10 reps, watch counted 9 (plan 10)", out)
            self.assertIn("total: replayed 10, watch 9, corrected 10 (repCorrection +1)", out)

    def test_no_wall_ball_step(self):
        with tempfile.TemporaryDirectory() as d:
            c = self.make_session(Path(d))
            c["splits"] = c["splits"][:1]
            (Path(d) / "coach.json").write_text(json.dumps(c))
            r = subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)

    def test_rep_ms_rounds_half_away_from_zero(self):
        self.assertEqual(wb.rep_ms(2.5e-3), 3)


if __name__ == "__main__":
    unittest.main()
