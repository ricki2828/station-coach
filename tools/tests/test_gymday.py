import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import desk_check  # noqa: E402
import gymday  # noqa: E402
import ingest  # noqa: E402
import m1_report  # noqa: E402

COACHED = TOOLS / "fixtures" / "coached-fixture"
INTERVAL = TOOLS / "fixtures" / "session-fixture"
ACTIVITIES = ["run", "transition", "skierg", "sled_push", "sled_pull", "burpee_broad_jump", "row", "farmers_carry", "sandbag_lunges", "wall_balls"]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # The fixtures are 3 minutes long; judge battery at 2 minutes instead of 90.
        p = mock.patch.object(m1_report, "BATTERY_MINUTES", 2)
        p.start()
        self.addCleanup(p.stop)

    def session(self, root, athlete, sid=None, source=COACHED):
        sid = sid or f"{athlete.lower()}-session"
        dest = Path(root) / athlete / sid
        shutil.copytree(source, dest)
        m = json.loads((dest / "manifest.json").read_text())
        m["athlete"], m["sessionId"] = athlete, sid
        (dest / "manifest.json").write_text(json.dumps(m))
        return dest

    def data_dir(self, athletes=("A1", "A2", "A3")):
        root = self.tmp / "data"
        for a in athletes:
            self.session(root, a)
        return root

    def run_gymday(self, root, *extra):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = gymday.main([str(root), "--min-minutes", "1", *extra])
        return code, buf.getvalue()

    @staticmethod
    def edit_json(path, fn):
        d = json.loads(Path(path).read_text())
        fn(d)
        Path(path).write_text(json.dumps(d))


class VerdictTests(Base):
    def test_full_pass_exits_zero(self):
        code, out = self.run_gymday(self.data_dir(), "--wb-truth", "a1-session=20")
        self.assertEqual(code, 0, out)
        self.assertIn("M1 gym-day verdict: PASS", out)
        self.assertIn("Coached checks (not M1 gates):", out)
        for n in "1234":
            self.assertRegex(out, rf"Mark {n}  PASS")
        self.assertIn("finish cue PASS", out)
        self.assertIn("wall-ball count PASS", out)
        self.assertIn("thermal worst fair", out)

    def test_two_athletes_only_fails_mark_4(self):
        code, out = self.run_gymday(self.data_dir(("A1", "A2")))
        self.assertEqual(code, 1)
        self.assertRegex(out, r"Mark 4  FAIL")
        self.assertIn("2 athlete code(s)", out)
        self.assertIn("M1 gym-day verdict: FAIL", out)

    def test_three_athletes_without_a1_fails_mark_4(self):
        code, out = self.run_gymday(self.data_dir(("A2", "A3", "A4")))
        self.assertEqual(code, 1)
        self.assertIn("no sessions for A1", out)

    def test_athlete_missing_an_activity_fails_mark_4(self):
        root = self.data_dir()
        labels = root / "A3" / "a3-session" / "labels.csv"
        labels.write_text("".join(l for l in labels.read_text().splitlines(keepends=True) if "row" not in l))
        code, out = self.run_gymday(root)
        self.assertEqual(code, 1)
        self.assertIn("A3 missing row", out)

    def test_finish_cue_never_issued_fails(self):
        root = self.data_dir()
        cues = root / "A1" / "a1-session" / "cues.csv"
        lines = cues.read_text().splitlines(keepends=True)
        assert "On target" in lines[-1] and "On target" in lines[-2]
        cues.write_text("".join(lines[:-2]))  # the finish cue's issued and finished rows
        _, out = self.run_gymday(root)
        self.assertIn("finish cue FAIL", out)
        self.assertIn("never issued", out)

    def test_finish_cue_issued_but_not_finished_fails(self):
        root = self.data_dir()
        cues = root / "A1" / "a1-session" / "cues.csv"
        lines = cues.read_text().splitlines(keepends=True)
        cues.write_text("".join(lines[:-1]))  # drops the finished row of the finish cue
        _, out = self.run_gymday(root)
        self.assertIn("finish cue FAIL", out)
        self.assertIn("never finished", out)

    def test_coached_failures_do_not_gate_the_verdict(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json", lambda d: d.update(repTimesMs=d["repTimesMs"][:17]))
        code, out = self.run_gymday(root, "--wb-truth", "a1-session=20")
        self.assertEqual(code, 0, out)
        self.assertIn("M1 gym-day verdict: PASS", out)
        self.assertIn("wall-ball count FAIL", out)

    def test_start_at_85_percent_is_not_comparable(self):
        root = self.data_dir()
        for a in ("A1", "A2", "A3"):
            b = root / a / f"{a.lower()}-session" / "battery.csv"
            b.write_text(b.read_text().replace("1.00,", "0.85,").replace("0.99,", "0.84,").replace("0.98,", "0.83,").replace("0.97,", "0.82,"))
        code, out = self.run_gymday(root)
        self.assertEqual(code, 1)
        self.assertRegex(out, r"Mark 2  NOT RUN")
        self.assertIn("battery start 85% < 95%: mark not comparable", out)

    def test_battery_below_mark_fails_mark_2(self):
        root = self.data_dir()
        b = root / "A2" / "a2-session" / "battery.csv"
        b.write_text(b.read_text().replace("0.99,", "0.20,").replace("0.98,", "0.20,").replace("0.97,", "0.20,"))
        code, out = self.run_gymday(root)
        self.assertEqual(code, 1)
        self.assertRegex(out, r"Mark 2  FAIL")

    def test_wall_balls_17_vs_20_fails(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json", lambda d: d.update(repTimesMs=d["repTimesMs"][:17]))
        _, out = self.run_gymday(root, "--wb-truth", "a1-session=20")
        self.assertIn("wall-ball count FAIL", out)
        self.assertIn("watch counted 17 vs true 20", out)

    def test_wall_balls_within_five_percent_passes(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json", lambda d: d.update(repTimesMs=d["repTimesMs"][:19]))
        code, out = self.run_gymday(root, "--wb-truth", "a1=20")  # id prefix
        self.assertEqual(code, 0, out)

    def test_phantom_rep_outside_wall_balls_fails(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json",
                       lambda d: d.update(repTimesMs=[d["startedAtEpochMs"] + 3000] + d["repTimesMs"]))
        _, out = self.run_gymday(root)
        self.assertIn("1 rep(s) outside the wall-ball steps", out)

    def test_early_session_with_unfinished_steps_is_ok_but_not_early_is_not(self):
        root = self.data_dir()
        path = root / "A1" / "a1-session" / "coach.json"
        self.edit_json(path, lambda d: d["splits"][-1].pop("endMs"))
        _, out = self.run_gymday(root)
        self.assertIn("splits FAIL", out)
        self.edit_json(path, lambda d: d.update(early=True))
        _, out = self.run_gymday(root)
        self.assertIn("splits PASS", out)
        self.assertIn("early:", out)

    def test_no_truth_is_not_run_and_does_not_fail(self):
        code, out = self.run_gymday(self.data_dir())
        self.assertEqual(code, 0, out)
        self.assertIn("wall-ball count NOT RUN", out)

    def test_battery_dying_before_90_minutes_fails_mark_2(self):
        # A 70-minute session that falls to 2% must FAIL, even though another session passes.
        root = self.data_dir()
        d = root / "A2" / "a2-session"
        start = 1_790_000_000_000
        self.edit_json(d / "manifest.json", lambda m: m.update(endedAtEpochMs=start + 70 * 60_000))
        (d / "battery.csv").write_text("epoch_ms,level,state\n" + "".join(
            f"{start + m * 60_000},{max(0.02, 1 - 0.014 * m):.2f},unplugged\n" for m in range(0, 71)))
        with mock.patch.object(m1_report, "BATTERY_MINUTES", 90):
            sessions = [gymday.analyse_session(f, None) for f in gymday.find_sessions(root)]
        a2 = next(s for s in sessions if s["athlete"] == "A2")
        self.assertEqual(a2["mark2"]["status"], "FAIL")
        self.assertIn("battery ran out", a2["mark2"]["detail"])
        v = gymday.verdict(sessions, 1, root)
        self.assertEqual(v["marks"][2]["status"], "FAIL")
        self.assertEqual(v["overall"], "FAIL")

    def test_short_session_projected_ok_stays_not_run(self):
        d = self.session(self.tmp / "data", "A1")
        with mock.patch.object(m1_report, "BATTERY_MINUTES", 90):
            s = gymday.analyse_session(d, None)
        self.assertEqual(s["mark2"]["status"], "NOT RUN")  # 0.5%/min over 3 min projects to ~55%

    def test_unmatched_or_ambiguous_wb_truth_is_an_error(self):
        root = self.data_dir()
        for key in ("nope=20", "a=20"):
            with self.assertRaises(SystemExit) as cm, redirect_stdout(io.StringIO()):
                gymday.main([str(root), "--min-minutes", "1", "--wb-truth", key])
            self.assertEqual(cm.exception.code, 2)

    def test_missing_ended_at_is_not_run_not_a_crash(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json", lambda d: (d.pop("endedAtEpochMs"), d["splits"][-1].pop("endMs")))
        code, out = self.run_gymday(root)
        self.assertEqual(code, 0, out)
        self.assertIn("coached checks NOT RUN: coach.json has no endedAtEpochMs", out)

    def test_motion_gap_fails_mark_3(self):
        root = self.data_dir()
        for name in ("accel", "motion"):
            p = root / "A1" / "a1-session" / f"{name}.csv"
            lines = p.read_text().splitlines(keepends=True)
            p.write_text("".join(lines[: 1 + 50 * 60]))
        code, out = self.run_gymday(root)
        self.assertEqual(code, 1)
        self.assertRegex(out, r"Mark 3  FAIL")

    def test_short_sessions_are_ignored(self):
        root = self.data_dir()
        code, out = self.run_gymday(root, "--min-minutes", "30")
        self.assertEqual(code, 1)
        self.assertIn("Ignored:", out)

    def test_json_and_md_outputs(self):
        root = self.data_dir()
        j, m = self.tmp / "v.json", self.tmp / "v.md"
        self.run_gymday(root, "--json", str(j), "--md", str(m))
        v = json.loads(j.read_text())
        self.assertEqual(v["overall"], "PASS")
        self.assertEqual(sorted(v["marks"]), ["1", "2", "3", "4"])
        self.assertIn("# M1 gym-day verdict: PASS", m.read_text())

    def test_interval_session_still_works(self):
        root = self.tmp / "data"
        self.session(root, "A1", source=INTERVAL)
        code, out = self.run_gymday(root)
        self.assertEqual(code, 1)  # one athlete and a flagged-missed cue: fails, but must not crash
        self.assertIn("Mark 1", out)

    def test_empty_dir(self):
        code, _ = self.run_gymday(self.tmp)
        self.assertEqual(code, 2)

    def test_replay_count_and_warnings_are_printed_when_the_module_exists(self):
        fake = mock.Mock()
        fake.replay.return_value = ({}, [{"replayed": [1, 2, 3], "watch": list(range(20)), "warnings": ["no labels.csv"]}])
        fake.corrected_counts.return_value = (18, 2)
        with mock.patch.object(gymday, "wallball_replay", fake):
            _, out = self.run_gymday(self.data_dir())
        self.assertIn("host replay counted 3, watch counted 20 (warnings: no labels.csv)", out)
        self.assertIn("corrected 18 valid + 2 no-rep", out)

    def test_replay_failure_is_not_run_not_a_crash(self):
        fake = mock.Mock()
        fake.replay.side_effect = RuntimeError("no motion.csv")
        fake.corrected_counts.return_value = (20, 0)
        with mock.patch.object(gymday, "wallball_replay", fake):
            code, out = self.run_gymday(self.data_dir())
        self.assertEqual(code, 0, out)
        self.assertIn("replay count NOT RUN: replay failed: no motion.csv", out)

    def test_corrected_figure_without_the_replay_module(self):
        root = self.data_dir()
        self.edit_json(root / "A1" / "a1-session" / "coach.json", lambda d: d.update(repCorrection=-2))
        with mock.patch.object(gymday, "wallball_replay", None):
            _, out = self.run_gymday(root)
        self.assertIn("watch counted 20 (corrected 18 valid)", out)


class TornRowTests(Base):
    """After a crash-resume a CSV can hold a short or garbled row mid-file; every reader must skip it and say so."""

    TEARS = {
        "labels.csv": "1790000010000,se\n",
        "cues.csv": "1790000010000,3,issued,speech,1\n",
        "battery.csv": "1790000010000,xx,unplugged\n",
        "hr.csv": "17900000100\n",
        "rates.csv": "1790000010000,accel\n",
        "events.csv": "garbled,thermal,nominal\n",
        "accel.csv": "1790000010000000,0.01000,-0.02\n",
        "motion.csv": "1790000010000000,0.01000,0.00000,0.000001790000010010000,0.01\n",
    }

    def tear(self, folder):
        for name, bad in self.TEARS.items():
            p = Path(folder) / name
            lines = p.read_text().splitlines(keepends=True)
            mid = len(lines) // 2
            p.write_text("".join(lines[:mid]) + bad + "".join(lines[mid:]))

    def test_torn_rows_are_skipped_counted_and_do_not_change_the_verdict(self):
        clean = self.data_dir()
        torn = self.tmp / "torn"
        shutil.copytree(clean, torn)
        for a in ("A1", "A2", "A3"):
            self.tear(torn / a / f"{a.lower()}-session")
        code_clean, out_clean = self.run_gymday(clean, "--wb-truth", "a1-session=20")
        code, out = self.run_gymday(torn, "--wb-truth", "a1-session=20")
        self.assertEqual((code, code_clean), (0, 0), out)
        self.assertIn("skipped malformed rows", out)
        for name in self.TEARS:
            self.assertIn(f"{name} 1", out)
        self.assertNotIn("skipped malformed rows", out_clean)
        for n in "1234":
            self.assertRegex(out, rf"Mark {n}  PASS")

    def test_json_carries_the_count(self):
        root = self.data_dir()
        self.tear(root / "A1" / "a1-session")
        j = self.tmp / "v.json"
        self.run_gymday(root, "--json", str(j))
        a1 = next(s for s in json.loads(j.read_text())["sessions"] if s["athlete"] == "A1")
        self.assertEqual(a1["tornRows"], {k: 1 for k in self.TEARS})

    def test_m1_report_skips_and_reports(self):
        s = self.session(self.tmp, "A1")
        self.tear(s)
        out = subprocess.run([sys.executable, str(TOOLS / "m1_report.py"), str(s)], capture_output=True, text=True, check=True).stdout
        self.assertIn("skipped malformed rows", out)
        self.assertIn("1. Cue delivery: 17/17", out)
        self.assertIn("100.0% of session seconds >= 50 Hz", out)

    def test_desk_check_survives_torn_rows(self):
        s = self.session(self.tmp, "A1")
        self.tear(s)
        self.assertEqual({st for _, st, _ in desk_check.run(s)}, {"PASS"})

    def test_ingest_files_a_torn_session_and_says_so(self):
        src = self.session(self.tmp / "src", "A2", "sid-torn")
        self.tear(src)
        filed, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertEqual(skipped, [])
        self.assertIn("skipped malformed rows", filed[0])

    def test_unterminated_quote_does_not_swallow_following_rows(self):
        s = self.session(self.tmp, "A1")
        cues = s / "cues.csv"
        lines = cues.read_text().splitlines(keepends=True)
        cues.write_text("".join(lines[:5]) + '1790000020000,9,issued,speech,1,"BluetoothA2DPOutput/Air\n' + "".join(lines[5:]))
        rows, skipped = m1_report.parse_csv(cues)
        self.assertEqual(skipped, 1)
        self.assertEqual(len(rows), len(lines) - 1)


class RoundTwoTests(Base):
    def test_wb_truth_on_an_uncoached_session_is_an_error(self):
        root = self.data_dir()
        self.session(root, "A4", "plain-one", source=INTERVAL)
        with self.assertRaises(SystemExit) as cm, redirect_stdout(io.StringIO()):
            gymday.main([str(root), "--min-minutes", "1", "--wb-truth", "plain-one=20"])
        self.assertEqual(cm.exception.code, 2)

    def test_quoted_newline_is_one_row(self):
        s = self.session(self.tmp, "A1")
        ev = s / "events.csv"
        ev.write_text(ev.read_text() + '1790000030000,error,"line one\nline two, with comma"\n1790000031000,thermal,fair\n')
        rows, skipped = m1_report.parse_csv(ev)
        self.assertEqual(skipped, 0)
        self.assertEqual(rows[-2]["detail"], "line one\nline two, with comma")
        self.assertEqual(rows[-1]["kind"], "thermal")

    def test_quoted_newline_at_end_of_file_and_torn_quote_before_a_row(self):
        s = self.session(self.tmp, "A1")
        ev = s / "events.csv"
        base = ev.read_text()
        ev.write_text(base + '1790000030000,error,"cut off\n1790000031000,thermal,fair\n')
        rows, skipped = m1_report.parse_csv(ev)
        self.assertEqual(skipped, 1)
        self.assertEqual(rows[-1]["kind"], "thermal")
        ev.write_text(base + '1790000030000,error,"never closed')
        self.assertEqual(m1_report.parse_csv(ev)[1], 1)

    def test_salvaged_session_finish_cue_is_not_run(self):
        root = self.data_dir()
        d = root / "A1" / "a1-session"
        self.edit_json(d / "manifest.json", lambda m: m.update(recovered=True))
        cues = d / "cues.csv"
        cues.write_text("".join(cues.read_text().splitlines(keepends=True)[:-2]))
        _, out = self.run_gymday(root)
        self.assertIn("finish cue NOT RUN: session was salvaged", out)

    def test_resumed_but_finished_session_still_checks_the_finish_cue(self):
        root = self.data_dir()
        d = root / "A1" / "a1-session"
        self.edit_json(d / "manifest.json", lambda m: m.update(resumed=1))
        cues = d / "cues.csv"
        cues.write_text("".join(cues.read_text().splitlines(keepends=True)[:-2]))
        _, out = self.run_gymday(root)
        self.assertIn("finish cue FAIL", out)

    def _short_battery_session(self, minutes, levels):
        d = self.session(self.tmp / f"d{minutes}", "A1")
        start = 1_790_000_000_000
        self.edit_json(d / "manifest.json", lambda m: m.update(endedAtEpochMs=start + minutes * 60_000))
        (d / "battery.csv").write_text("epoch_ms,level,state\n" + "".join(
            f"{start + i * 60_000},{lv:.2f},unplugged\n" for i, lv in enumerate(levels)))
        with mock.patch.object(m1_report, "BATTERY_MINUTES", 90):
            return gymday.analyse_session(d, None)["mark2"]

    def test_projection_needs_twenty_minutes(self):
        # 1%/min projects to 10% at 90 min: FAIL from a 30-minute session, NOT RUN from a 10-minute one.
        long_ = self._short_battery_session(30, [1 - 0.01 * i for i in range(31)])
        self.assertEqual(long_["status"], "FAIL")
        short = self._short_battery_session(10, [1 - 0.01 * i for i in range(11)])
        self.assertEqual(short["status"], "NOT RUN")
        self.assertIn("too short to project", short["detail"])

    def test_flat_battery_fails_even_in_a_short_session(self):
        m = self._short_battery_session(10, [1.0, 0.5, 0.2, 0.05, 0.03])
        self.assertEqual(m["status"], "FAIL")
        self.assertIn("ran out", m["detail"])


class IngestTests(Base):
    def make_zip(self, folder, name, prefix=None):
        z = self.tmp / name
        with zipfile.ZipFile(z, "w") as zf:
            for f in Path(folder).rglob("*"):
                if f.is_file():
                    zf.write(f, f"{prefix or Path(folder).name}/{f.relative_to(folder)}")
        return z

    def test_ingests_zip_and_files_by_athlete(self):
        src = self.session(self.tmp / "src", "A2", "sid-one")
        z = self.make_zip(src, "one.zip")
        filed, skipped = ingest.ingest([z], self.tmp / "out")
        self.assertEqual((len(filed), skipped), (1, []))
        self.assertTrue((self.tmp / "out" / "A2" / "sid-one" / "coach.json").is_file())

    def test_duplicate_session_id_is_skipped(self):
        src = self.session(self.tmp / "src", "A2", "sid-one")
        z = self.make_zip(src, "one.zip")
        ingest.ingest([z], self.tmp / "out")
        filed, skipped = ingest.ingest([z, src], self.tmp / "out")
        self.assertEqual(filed, [])
        self.assertEqual(len(skipped), 2)
        self.assertTrue(all("duplicate sessionId" in s for s in skipped))
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(ingest.main([str(z), "--into", str(self.tmp / "out")]), 0)

    def test_missing_listed_file_is_skipped_with_reason(self):
        src = self.session(self.tmp / "src", "A2", "sid-two")
        (src / "hr.csv").unlink()
        filed, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertEqual(filed, [])
        self.assertIn("hr.csv listed in manifest but missing", skipped[0])

    def test_wrong_csv_header_is_skipped(self):
        src = self.session(self.tmp / "src", "A2", "sid-three")
        (src / "battery.csv").write_text("time,pct\n1,2\n")
        _, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertIn("battery.csv header", skipped[0])

    def test_unfinished_manifest_is_skipped(self):
        src = self.session(self.tmp / "src", "A2", "sid-four")
        self.edit_json(src / "manifest.json", lambda d: d.pop("files"))
        _, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertIn("never finished", skipped[0])

    def test_folder_of_sessions(self):
        for a in ("A1", "A2"):
            self.session(self.tmp / "src", a)
        filed, skipped = ingest.ingest([self.tmp / "src"], self.tmp / "out")
        self.assertEqual((len(filed), skipped), (2, []))

    def test_refuses_to_write_inside_the_repo(self):
        with self.assertRaises(SystemExit):
            ingest.ingest([COACHED], TOOLS.parent / "leaked-data")

    def test_symlink_in_folder_input_is_skipped(self):
        src = self.session(self.tmp / "src", "A2", "sid-link")
        (src / "notes.txt").symlink_to(self.tmp / "secret.txt")
        filed, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertEqual(filed, [])
        self.assertIn("symlinks", skipped[0])

    def test_oversized_zip_is_refused(self):
        z = self.make_zip(self.session(self.tmp / "src", "A2", "sid-big"), "big.zip")
        with mock.patch.object(ingest, "MAX_UNCOMPRESSED", 1000):
            _, skipped = ingest.ingest([z], self.tmp / "out")
        self.assertIn("over the", skipped[0])

    def test_zip_slip_is_refused(self):
        z = self.tmp / "evil.zip"
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("../escape.txt", "x")
        _, skipped = ingest.ingest([z], self.tmp / "out")
        self.assertIn("unsafe path", skipped[0])
        self.assertFalse((self.tmp / "escape.txt").exists())

    def test_bad_athlete_code_is_skipped(self):
        src = self.session(self.tmp / "src", "A2", "sid-five")
        self.edit_json(src / "manifest.json", lambda d: d.update(athlete="../x"))
        _, skipped = ingest.ingest([src], self.tmp / "out")
        self.assertIn("bad athlete code", skipped[0])

    def test_ingest_then_gymday(self):
        zips = [self.make_zip(self.session(self.tmp / "src", a), f"{a}.zip") for a in ("A1", "A2", "A3")]
        ingest.ingest(zips, self.tmp / "out")
        code, out = self.run_gymday(self.tmp / "out")
        self.assertEqual(code, 0, out)


class DeskCheckTests(Base):
    def results(self, folder):
        return {name: (status, detail) for name, status, detail in desk_check.run(folder)}

    def test_coached_fixture_passes_the_desk_checks(self):
        r = self.results(COACHED)
        self.assertEqual({k: v[0] for k, v in r.items()},
                         {"mode=speech": "PASS", "A2DP output": "PASS", "headphones lost -> reactivated": "PASS",
                          "rates.csv every minute": "PASS"})

    def test_haptic_only_cue_fails_speech_mode(self):
        self.assertEqual(self.results(INTERVAL)["mode=speech"][0], "FAIL")

    def test_no_lost_event_is_not_run(self):
        self.assertEqual(self.results(INTERVAL)["headphones lost -> reactivated"][0], "NOT RUN")

    def test_lost_without_reactivation_fails(self):
        s = self.session(self.tmp, "A1")
        ev = s / "events.csv"
        ev.write_text("".join(l for l in ev.read_text().splitlines(keepends=True) if "reactivating" not in l))
        self.assertEqual(self.results(s)["headphones lost -> reactivated"][0], "FAIL")

    def test_missing_rates_rows_fail(self):
        s = self.session(self.tmp, "A1")
        r = s / "rates.csv"
        r.write_text("".join(r.read_text().splitlines(keepends=True)[:3]))
        self.assertEqual(self.results(s)["rates.csv every minute"][0], "FAIL")

    def test_recovered_session_skips_rates_check(self):
        s = self.session(self.tmp, "A1")
        self.edit_json(s / "manifest.json", lambda d: d.update(recovered=True))
        self.assertEqual(self.results(s)["rates.csv every minute"][0], "NOT RUN")

    def test_cli_exit_code(self):
        run = lambda p: subprocess.run([sys.executable, str(TOOLS / "desk_check.py"), str(p)], capture_output=True, text=True).returncode
        self.assertEqual(run(COACHED), 0)
        self.assertEqual(run(INTERVAL), 1)


if __name__ == "__main__":
    unittest.main()
