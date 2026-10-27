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
        self.assertGreaterEqual(len(EXPECTED), 15)
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
        # Boundary scenarios.
        self.assertEqual(EXPECTED["min_interval_edge"]["count"], 9)
        self.assertEqual(EXPECTED["catch_late"]["count"], 8)
        self.assertEqual(EXPECTED["ignore_edge"]["count"], 7)
        self.assertEqual(EXPECTED["jog_hold_edge"]["count"], 5)
        self.assertEqual(EXPECTED["low_amp"]["count"], 8)
        self.assertEqual(EXPECTED["uneven"]["count"], 7)
        self.assertEqual(EXPECTED["rest_edge"]["count"], 9)
        self.assertEqual(EXPECTED["sub_floor"]["count"], 0)
        self.assertEqual(EXPECTED["after_big_bump"]["count"], 8)
        self.assertEqual({n for n, w in EXPECTED.items() if w["confidence"] == "low"}, {"uneven", "sub_floor"})  # sub_floor: no reps is low by definition

    def test_smoothing_is_bit_identical_to_swift_expression(self):
        """Swift: smooth.map { $0 * 0.8 + magnitude * 0.2 }. Compare exactly, not approximately."""
        c = wb.WallBallCounter()
        ref = None
        for t, m in read_samples("steady"):
            ref = m if ref is None else ref * 0.8 + m * 0.2
            c.add(t, m)
            self.assertEqual(c._smooth, ref)

    def test_mutants_are_caught(self):
        """Each parameter nudged must change at least one golden, so the fixtures cannot go soft."""
        C = wb.WallBallCounter
        mutants = [("DEFAULT_MIN_INTERVAL", v) for v in (1.5, 1.85)] + [("DEFAULT_IGNORE_FIRST", v) for v in (3.0, 5.0)] \
            + [("MIN_THRESHOLD", v) for v in (0.4, 0.8)] + [("ENVELOPE_FRACTION", v) for v in (0.4, 0.6)] \
            + [("JOGGING_HOLD", v) for v in (0.5, 3.0)] + [("JOGGING_PEAKS", v) for v in (3, 5)] \
            + [("JOGGING_WINDOW", v) for v in (1.5, 2.5)] + [("REST_GAP", v) for v in (2.0, 12.0)] \
            + [("CONF_MAX_CV", v) for v in (0.01, 0.8)] + [("SMOOTH_KEEP", v) for v in (0.6, 0.9)] \
            + [("SMOOTH_NEW", v) for v in (0.1, 0.4)]
        data = {n: read_samples(n) for n in EXPECTED}

        def outputs():
            res = {}
            for n, rows in data.items():
                c = wb.WallBallCounter()
                for t, m in rows:
                    c.add(t, m)
                res[n] = (c.count, c.confidence, [round(x, 2) for x in c.rep_times])
            return res

        want = {n: (w["count"], w["confidence"], w["repTimes"]) for n, w in EXPECTED.items()}
        self.assertEqual(outputs(), want)
        survivors = []
        for attr, val in mutants:
            old = getattr(C, attr)
            setattr(C, attr, val)
            try:
                if outputs() == want:
                    survivors.append((attr, val))
            finally:
                setattr(C, attr, old)
        self.assertEqual(survivors, [])

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
            self.assertIn("total: replayed 10, watch 9, corrected 10 valid + 0 no-rep (repCorrection +1)", out)

    def test_no_wall_ball_step(self):
        with tempfile.TemporaryDirectory() as d:
            c = self.make_session(Path(d))
            c["splits"] = c["splits"][:1]
            (Path(d) / "coach.json").write_text(json.dumps(c))
            r = subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)

    def write_labels(self, tmp, rows):
        (tmp / "labels.csv").write_text("epoch_ms,event,activity\n" + "".join(f"{a},{b},{c}\n" for a, b, c in rows))

    def test_paused_gap_is_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            self.make_session(tmp)
            # Advanced off wall balls at +12 s by mistake, undone at +21 s: reps at 14.18..20.19 were not counted live.
            self.write_labels(tmp, [(T0 - 60_000, "set", "run"), (T0, "set", "wall_balls"),
                                    (T0 + 12_000, "set", "rest"), (T0 + 21_000, "set", "wall_balls")])
            coach, steps = wb.replay(tmp)
            self.assertEqual(steps[0]["paused"], [(T0 + 12_000, T0 + 21_000)])
            # 5.19 8.19 11.18 before the gap, 23.19 26.19 29.18 32.19 after it; 14.18 17.19 20.19 were not counted live
            self.assertEqual(len(steps[0]["replayed"]), 7)
            self.assertEqual(steps[0]["warnings"], [])

    def test_undo_event_pops_label(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            self.make_session(tmp)
            self.write_labels(tmp, [(T0, "set", "wall_balls"), (T0 + 12_000, "set", "rest"), (T0 + 21_000, "undo", "")])
            _, steps = wb.replay(tmp)
            self.assertEqual(steps[0]["paused"], [(T0 + 12_000, T0 + 21_000)])

    def test_no_labels_flags_the_step(self):
        with tempfile.TemporaryDirectory() as d:
            self.make_session(Path(d))
            _, steps = wb.replay(d)
            self.assertEqual(steps[0]["paused"], [])
            self.assertIn("no labels.csv", steps[0]["warnings"][0])
            out = subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), d], capture_output=True, text=True).stdout
            self.assertIn("warning: no labels.csv", out)

    def test_corrected_matches_app_rule(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            base = {"repTimesMs": [1] * 10, "repCorrection": 2, "noReps": [{"tMs": 1, "setIndex": 0}] * 2}
            self.assertEqual(wb.corrected_counts(base, tmp), (10, 2))  # 10 + 2 - 2
            self.assertEqual(wb.corrected_counts({"repTimesMs": [1], "repCorrection": -5}, tmp), (0, 0))
            self.assertEqual(wb.corrected_counts({**base, "wallBallCorrection": {"validReps": 7, "noReps": 1}}, tmp), (7, 1))
            # Legacy bare Int = total throws, the logged taps are the no-reps.
            self.assertEqual(wb.corrected_counts({**base, "wallBallCorrection": 12}, tmp), (10, 2))
            # The phone's sidecar wins over coach.json, clamped like the app.
            (tmp / "phone-correction.json").write_text('{"validReps": 999, "noReps": 3}')
            self.assertEqual(wb.corrected_counts({**base, "wallBallCorrection": {"validReps": 7, "noReps": 1}}, tmp), (300, 3))

    def test_cli_prints_no_reps(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            c = self.make_session(tmp)
            c["noReps"] = [{"tMs": T0 + 9000, "setIndex": 0}, {"tMs": T0 + 12000, "setIndex": 0}]
            (tmp / "coach.json").write_text(json.dumps(c))
            out = subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), d], capture_output=True, text=True).stdout
            self.assertIn("corrected 8 valid + 2 no-rep", out)

    def cli(self, d):
        return subprocess.run([sys.executable, str(TOOLS / "wallball_replay.py"), str(d)], capture_output=True, text=True)

    def test_missing_files_are_errors_not_tracebacks(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            r = self.cli(tmp)
            self.assertEqual((r.returncode, "Traceback" in r.stderr), (1, False))
            self.assertIn("no coach.json", r.stdout)
            self.make_session(tmp)
            (tmp / "motion.csv").unlink()
            r = self.cli(tmp)
            self.assertEqual((r.returncode, "Traceback" in r.stderr), (1, False))
            self.assertIn("no motion.csv", r.stdout)
            (tmp / "coach.json").write_text("{not json")
            r = self.cli(tmp)
            self.assertEqual((r.returncode, "Traceback" in r.stderr), (1, False))
            self.assertIn("unreadable", r.stdout)

    def test_count_reps_never_raises_on_data(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            warn = []
            self.assertEqual(wb.count_reps(tmp / "nope.csv", 0, 1, warnings=warn), [])
            self.assertIn("cannot read", warn[0])
            self.make_session(tmp)
            text = (tmp / "motion.csv").read_text()
            # Torn last row, a short row and a garbage row.
            (tmp / "motion.csv").write_text(text + "1790000040000000,0.5\n1790000040010000,x,0,0,0,0,0,0,0,-1\n17900000400200")
            warn = []
            reps = wb.count_reps(tmp / "motion.csv", T0, T0 + 50_000, warnings=warn)
            self.assertEqual(len(reps), 10)
            self.assertIn("skipped 3", warn[0])
            self.assertEqual(wb.count_reps(tmp / "motion.csv", T0, T0 + 50_000), reps)  # no warnings list: still fine

    def test_torn_rows_mid_file_after_crash_resume(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            self.make_session(tmp)
            lines = (tmp / "motion.csv").read_text().split("\n")
            n = len(lines)
            # A resumed writer appends after a torn line: a short row, a torn fragment glued onto the next row
            # (extra fields), and a fragment glued on so the field count looks right but the timestamp is wild.
            lines[n // 3] = lines[n // 3][:20]
            lines[n // 2] = lines[n // 2][:25] + lines[n // 2 + 1]
            del lines[n // 2 + 1]
            lines[2 * n // 3] = "17" + lines[2 * n // 3]
            (tmp / "motion.csv").write_text("\n".join(lines))
            warn = []
            reps = wb.count_reps(tmp / "motion.csv", T0, T0 + 40_000, warnings=warn)
            self.assertGreaterEqual(len(reps), 9)  # a few lost samples may cost a rep, never the rest of the file
            self.assertTrue(reps[-1] > T0 + 25_000, "replay continued past the torn rows")
            self.assertRegex(warn[0], r"skipped [3-9] torn")

    def test_recovered_resume_inside_step_warns(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            self.make_session(tmp)
            (tmp / "events.csv").write_text(f"epoch_ms,kind,detail\n{T0 - 90_000},recovered_resume,step=0\n"
                                            f"{T0 + 15_000},recovered_resume,step=1 splits=2 seq=9\n")
            _, steps = wb.replay(tmp)
            joined = " ".join(steps[0]["warnings"])
            self.assertIn(f"recovered_resume at {T0 + 15_000}", joined)
            self.assertNotIn(str(T0 - 90_000), joined)  # outside the wall-ball step

    def test_rep_ms_rounds_half_away_from_zero(self):
        self.assertEqual(wb.rep_ms(2.5e-3), 3)


if __name__ == "__main__":
    unittest.main()
