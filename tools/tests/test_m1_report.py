import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import m1_report  # noqa: E402

FIXTURE = TOOLS / "fixtures" / "session-fixture"
T0 = 1_790_000_000_000
MIN = 60_000


def run_cli(folder):
    return subprocess.run([sys.executable, str(TOOLS / "m1_report.py"), str(folder)],
                          capture_output=True, text=True, check=True).stdout


class ReportTests(unittest.TestCase):
    def test_cue_delivery(self):
        r = m1_report.cue_delivery(m1_report.read_rows(FIXTURE / "cues.csv"))
        self.assertEqual((r["issued"], r["delivered"], r["haptic_only"], r["missed"]), (12, 10, 1, 1))
        self.assertEqual(r["route_headphones"], 11)
        self.assertEqual(r["any_route"], 10)
        self.assertEqual(r["audio_modes"], ["A"])
        self.assertAlmostEqual(r["percent"], 100 * 10 / 12)

    def test_cue_delivery_empty(self):
        self.assertEqual(m1_report.cue_delivery([])["percent"], 0.0)

    def test_expected_cues(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        self.assertEqual(m1_report.expected_cues(m1_report.load_manifest(FIXTURE), start, end), 12)

    def test_battery_at_90(self):
        rows = [{"epoch_ms": str(T0 + m * MIN), "level": f"{1 - 0.005 * m:.2f}", "state": "unplugged"} for m in range(101)]
        b = m1_report.battery_at(rows, T0, T0 + 100 * MIN)
        self.assertTrue(b["reached"])
        self.assertAlmostEqual(b["percent"], 55.0, places=3)

    def test_battery_projection_when_session_short(self):
        rows = [{"epoch_ms": str(T0 + m * MIN), "level": f"{1 - 0.01 * m:.2f}", "state": "unplugged"} for m in range(0, 31)]
        b = m1_report.battery_at(rows, T0, T0 + 30 * MIN)
        self.assertFalse(b["reached"])
        self.assertAlmostEqual(b["drain_per_min"], 1.0, places=3)
        self.assertAlmostEqual(b["percent"], 10.0, places=3)

    def test_battery_unknown_readings(self):
        rows = [{"epoch_ms": str(T0), "level": "-1.00", "state": "unknown"}]
        self.assertFalse(m1_report.battery_at(rows, T0, T0 + MIN)["known"])

    def test_achieved_hz(self):
        for name in ("accel", "motion"):
            r = m1_report.achieved_hz(FIXTURE / f"{name}.csv")
            self.assertEqual(r["samples"], 12000)
            self.assertAlmostEqual(r["median_hz"], 100.0)
            self.assertAlmostEqual(r["mean_hz"], 100.0, delta=0.1)

    def test_achieved_hz_missing_file(self):
        self.assertIsNone(m1_report.achieved_hz(FIXTURE / "nope.csv"))

    def test_full_coverage(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        c = m1_report.motion_coverage(FIXTURE / "accel.csv", start, end)
        self.assertEqual((c["coverage"], c["longest_gap_s"], c["seconds"]), (1.0, 0, 120))

    def test_missing_stream_is_zero_coverage(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        c = m1_report.motion_coverage(FIXTURE / "nope.csv", start, end)
        self.assertEqual((c["coverage"], c["longest_gap_s"]), (0.0, 120))

    def test_label_minutes_with_undo(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        m = m1_report.label_minutes(m1_report.read_rows(FIXTURE / "labels.csv"), start, end)
        expected_s = {
            "run": 20, "transition": 10, "skierg": 10, "sled_push": 10, "sled_pull": 10,
            "burpee_broad_jump": 10, "row": 10, "farmers_carry": 10, "sandbag_lunges": 10, "wall_balls": 20,
        }
        for act, secs in expected_s.items():
            self.assertAlmostEqual(m[act] * 60, secs, places=6, msg=act)
        self.assertNotIn("rest", m)
        self.assertAlmostEqual(m["_unlabelled"], 0.0, places=6)

    def test_report_text_and_cli(self):
        out = run_cli(FIXTURE)
        self.assertIn("1. Cue delivery: 10/12 = 83.3%", out)
        self.assertIn("FAIL (mark 95%)", out)
        self.assertIn("cues issued 12 of ~12 expected", out)
        self.assertIn("athlete flagged 'didn't hear' 1 (8% tap rate)", out)
        self.assertIn("accel 100 Hz median", out)
        self.assertIn("100.0% of session seconds", out)
        self.assertIn("PASS all 10 activities", out)

    def test_main_without_args(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(m1_report.main(["m1_report.py"]), 2)


class AthleteTests(unittest.TestCase):
    def test_groups_by_athlete(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        import json
        folders = []
        for name, athlete in (("s1", "A1"), ("s2", "A1"), ("s3", "A2")):
            f = tmp / name
            shutil.copytree(FIXTURE, f)
            m = json.loads((f / "manifest.json").read_text())
            m["athlete"] = athlete
            (f / "manifest.json").write_text(json.dumps(m))
            folders.append(f)
        text = "\n".join(m1_report.athlete_summary(folders))
        self.assertIn("A1: 2 session(s), wrist left, 4.0 min labelled, all 10 activities", text)
        self.assertIn("A2: 1 session(s)", text)
        self.assertIn("run=0.7", text)  # A1: 2 x 20 s = 0.67 min

    def test_absent_activity_fails_the_aggregate(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        f = tmp / "s"
        shutil.copytree(FIXTURE, f)
        rows = (f / "labels.csv").read_text().splitlines(keepends=True)
        (f / "labels.csv").write_text("".join(r for r in rows if "wall_balls" not in r))
        text = "\n".join(m1_report.athlete_summary([f]))
        self.assertIn("missing wall_balls", text)
        self.assertNotIn("all 10 activities", text)
        self.assertEqual(m1_report.missing_activities({"run": 3.0}), [a for a in m1_report.ACTIVITIES if a != "run"])

    def test_missing_athlete_is_grouped_unknown(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        f = tmp / "s"
        shutil.copytree(FIXTURE, f)
        import json
        m = json.loads((f / "manifest.json").read_text())
        del m["athlete"]
        (f / "manifest.json").write_text(json.dumps(m))
        self.assertIn("?: 1 session(s)", "\n".join(m1_report.athlete_summary([f])))


class DegradedSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.folder = self.tmp / "s"
        shutil.copytree(FIXTURE, self.folder)

    @staticmethod
    def keep_lines(path, n):
        lines = path.read_text().splitlines(keepends=True)
        path.write_text("".join(lines[:n]))

    def test_motion_dies_halfway_fails_hz_mark(self):
        for name in ("accel", "motion"):
            self.keep_lines(self.folder / f"{name}.csv", 1 + 60 * 100)  # header + first 60 s
        start, end = m1_report.session_bounds(m1_report.load_manifest(self.folder), self.folder)
        c = m1_report.motion_coverage(self.folder / "accel.csv", start, end)
        self.assertAlmostEqual(c["coverage"], 0.5)
        self.assertEqual(c["longest_gap_s"], 60)
        out = run_cli(self.folder)
        line = next(l for l in out.splitlines() if l.startswith("3."))
        self.assertIn("50.0% of session seconds", line)
        self.assertIn("longest gap 60 s", line)
        self.assertIn("FAIL (mark 50 Hz)", line)

    def test_cues_stop_early_fails_even_if_delivered(self):
        rows = (self.folder / "cues.csv").read_text().splitlines(keepends=True)
        kept = [rows[0]] + [r for r in rows[1:] if int(r.split(",")[1]) in (1, 2, 3, 4)]
        (self.folder / "cues.csv").write_text("".join(kept))
        out = run_cli(self.folder)
        self.assertIn("1. Cue delivery: 4/4 = 100.0%", out)
        self.assertIn("cues issued 4 of ~12 expected (33%", out)
        line = next(l for l in out.splitlines() if l.startswith("1."))
        self.assertIn("FAIL", line)


if __name__ == "__main__":
    unittest.main()
