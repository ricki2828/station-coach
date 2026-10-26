import io
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import m1_report  # noqa: E402

FIXTURE = TOOLS / "fixtures" / "session-fixture"
T0 = 1_790_000_000_000
MIN = 60_000


class ReportTests(unittest.TestCase):
    def test_cue_delivery(self):
        r = m1_report.cue_delivery(m1_report.read_rows(FIXTURE / "cues.csv"))
        self.assertEqual((r["issued"], r["delivered"], r["haptic_only"], r["missed"]), (20, 18, 1, 1))
        self.assertAlmostEqual(r["percent"], 90.0)

    def test_cue_delivery_empty(self):
        self.assertEqual(m1_report.cue_delivery([])["percent"], 0.0)

    def test_battery_at_90(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        b = m1_report.battery_at(m1_report.read_rows(FIXTURE / "battery.csv"), start, end)
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
            self.assertEqual(r["samples"], 2000)
            self.assertAlmostEqual(r["median_hz"], 100.0)
            self.assertAlmostEqual(r["mean_hz"], 100.0, delta=0.1)

    def test_achieved_hz_missing_file(self):
        self.assertIsNone(m1_report.achieved_hz(FIXTURE / "nope.csv"))

    def test_label_minutes_with_undo(self):
        start, end = m1_report.session_bounds(m1_report.load_manifest(FIXTURE), FIXTURE)
        m = m1_report.label_minutes(m1_report.read_rows(FIXTURE / "labels.csv"), start, end)
        expected = {
            "run": 56, "transition": 2, "skierg": 5, "sled_push": 3, "sled_pull": 3,
            "burpee_broad_jump": 5, "row": 6, "farmers_carry": 4, "sandbag_lunges": 6, "wall_balls": 10,
        }
        for act, mins in expected.items():
            self.assertAlmostEqual(m[act], mins, places=6, msg=act)
        self.assertNotIn("rest", m)
        self.assertAlmostEqual(m["_unlabelled"], 0.0, places=6)

    def test_report_text_and_cli(self):
        out = subprocess.run([sys.executable, str(TOOLS / "m1_report.py"), str(FIXTURE)],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("1. Cue delivery: 18/20 = 90.0%", out)
        self.assertIn("FAIL (mark 95%)", out)
        self.assertIn("2. Battery at 90 min: 55%", out)
        self.assertIn("PASS (mark 30%)", out)
        self.assertIn("accel 100 Hz median", out)
        self.assertIn("PASS all 10 activities", out)

    def test_main_without_args(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(m1_report.main(["m1_report.py"]), 2)


if __name__ == "__main__":
    unittest.main()
