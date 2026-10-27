#!/usr/bin/env python3
"""One verdict for gym day: the four M1 pass marks over every ingested session.

    python3 tools/gymday.py <data-dir> [--wb-truth <session>=20 ...] [--json out.json] [--md out.md]
                                      [--min-minutes 10]

<data-dir> is what tools/ingest.py filled (any layout works: every folder with a manifest.json counts).
Marks (docs/GYMDAY.md has the rules in full):
  1. speech cues heard on headphones >= 95%, in every session
  2. >= 30% battery at 90 minutes, in every comparable session (start >= 95%) that reached 90 minutes
  3. motion stored at >= 50 Hz for >= 95% of session seconds, in every session
  4. at least 3 athlete codes including A1, each with all 10 activities
Coached sessions (coach.json) also get the PROTOCOL checks, printed apart as "Coached checks (not M1 gates)":
finish cue spoken to the end, splits complete or early, wall-ball count against --wb-truth (+-5%), phantom reps
outside the wall-ball steps. They never change the M1 verdict or the exit code.
Exit code 0 only when all four marks PASS; 2 on bad input.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import m1_report as m1  # noqa: E402

try:  # optional: tools/wallball_replay.py (PR #15): host replay of the wall-ball counter, and the app's corrected-count rule
    import wallball_replay
except ImportError:
    wallball_replay = None

PASS, FAIL, NOT_RUN = "PASS", "FAIL", "NOT RUN"
WB_TOLERANCE = 0.05
MIN_ATHLETES = 3
BATTERY_PROJECT_MIN_MINUTES = 20  # a straight-line projection from fewer minutes of coarse readings is too noisy to FAIL on
BATTERY_FLAT = 5.0  # percent: a last reading at or under this before 90 min counts as the battery running out
REQUIRED_ATHLETE = "A1"
THERMAL_ORDER = ["nominal", "fair", "serious", "critical"]


def find_sessions(data_dir):
    return sorted(p.parent for p in Path(data_dir).rglob("manifest.json"))


def check(name, status, detail):
    return {"name": name, "status": status, "detail": detail}


def thermal_worst(folder):
    states = [r["detail"].strip() for r in m1.read_rows(Path(folder) / "events.csv") if r.get("kind") == "thermal"]
    known = [s for s in states if s in THERMAL_ORDER]
    return max(known, key=THERMAL_ORDER.index) if known else None


def wall_ball_windows(coach):
    """(start_ms, end_ms) of every wall-ball step that has a finished or quit split."""
    plan = {s["index"]: s for s in coach["plan"]["steps"]}
    out = []
    for sp in coach["splits"]:
        if sp.get("skipped"):
            continue  # an abandoned attempt (skipped or moved): its reps are not wall-ball reps
        if plan.get(sp["stepIndex"], {}).get("activity") == "wall_balls":
            out.append((sp["startMs"], sp.get("endMs") or coach["endedAtEpochMs"]))
    return out


def coached_checks(folder, manifest, truth):
    coach_path = Path(folder) / "coach.json"
    if not coach_path.exists():
        return []
    try:
        coach = json.loads(coach_path.read_text())
        coach["plan"]["steps"], coach["splits"]
    except (ValueError, KeyError, TypeError) as e:
        return [check("coach.json", FAIL, f"unreadable ({e})")]
    if not isinstance(coach.get("endedAtEpochMs"), int):
        return [check("coached checks", NOT_RUN, "coach.json has no endedAtEpochMs (session not closed cleanly?)")]
    checks = []

    # Finish cue: the first cue issued at or after the session ended (the watch offers it after the undo window).
    ended = coach["endedAtEpochMs"]
    by_id = {}
    for r in m1.read_rows(Path(folder) / "cues.csv"):
        by_id.setdefault(r["cue_id"], []).append(r)
    issued = [(min(int(e["epoch_ms"]) for e in ev if e["event"] == "issued"), cid, ev)
              for cid, ev in by_id.items() if any(e["event"] == "issued" for e in ev)]
    after = [t for t in issued if t[0] >= ended]
    # Salvaged = closed from a checkpoint: recovered and either ended early or no finish cue ever followed.
    # A recovered session that finished normally (crash after FINISH) is still checked.
    salvaged = bool(manifest.get("recovered")) and (bool(coach.get("early")) or not after)
    if salvaged:
        checks.append(check("finish cue", NOT_RUN, "session was salvaged from a checkpoint (recovered): no finish cue is expected"))
    elif not after:
        checks.append(check("finish cue", FAIL, "never issued (no cue at or after the session end)"))
    else:
        _, cid, ev = min(after, key=lambda t: t[0])
        kinds = {e["event"] for e in ev}
        ok = "finished" in kinds
        checks.append(check("finish cue", PASS if ok else FAIL,
                            f"cue {cid} issued" + (" and finished" if ok else f", never finished (saw: {', '.join(sorted(kinds))})")))

    # Splits.
    steps = coach["plan"]["steps"]
    done = {s["stepIndex"] for s in coach["splits"] if s.get("endMs") is not None and not s.get("skipped")}
    missing = [s["index"] for s in steps if s["index"] not in done]
    skipped = sorted({s["stepIndex"] for s in coach["splits"] if s.get("skipped")} - done)
    if skipped and not coach.get("early"):
        checks.append(check("splits", FAIL, f"stations skipped (not a full session): {skipped}"))
    elif not missing:
        checks.append(check("splits", PASS, f"all {len(steps)} steps have a split"))
    elif coach.get("early"):
        checks.append(check("splits", PASS, f"early: {len(steps) - len(missing)}/{len(steps)} steps finished"))
    else:
        checks.append(check("splits", FAIL, f"not early but steps without an end: {missing}"))

    # Wall balls.
    windows = wall_ball_windows(coach)
    reps = coach.get("repTimesMs", [])
    if windows:
        inside = [t for t in reps if any(a <= t <= b for a, b in windows)]
        phantom = len(reps) - len(inside)
        checks.append(check("phantom reps", PASS if phantom == 0 else FAIL,
                            f"{phantom} rep(s) outside the wall-ball steps" if phantom else "none outside the wall-ball steps"))
    watch = len(reps)
    if wallball_replay is not None:  # the app's rule, phone-correction.json included, shared with the replay tool
        valid, no_rep = wallball_replay.corrected_counts(coach, folder)
        corrected = f"{valid} valid + {no_rep} no-rep"
    else:  # without #15: coach.json only (phone-correction.json is not read)
        corr = coach.get("wallBallCorrection")
        valid = corr["validReps"] if isinstance(corr, dict) else max(0, watch + coach.get("repCorrection", 0) - len(coach.get("noReps", [])))
        corrected = f"{valid} valid"
    if truth is None:
        checks.append(check("wall-ball count", NOT_RUN, f"watch counted {watch} (corrected {corrected}); pass --wb-truth <session>=N"))
    else:
        off = abs(watch - truth)
        ok = off <= WB_TOLERANCE * truth + 1e-9
        checks.append(check("wall-ball count", PASS if ok else FAIL,
                            f"watch counted {watch} vs true {truth} ({100 * (watch - truth) / truth:+.0f}%, "
                            f"limit +-{100 * WB_TOLERANCE:.0f}%); corrected {corrected}"))
    if wallball_replay is not None and windows:
        try:
            _, steps = wallball_replay.replay(folder)
            replayed = sum(len(st["replayed"]) for st in steps)
            watch_steps = sum(len(st["watch"]) for st in steps)
            notes = [w for st in steps for w in st["warnings"]]
            checks.append(check("replay count", NOT_RUN, f"host replay counted {replayed}, watch counted {watch_steps}"
                                + (f" (warnings: {'; '.join(notes)})" if notes else "")))
        except Exception as e:  # a replay problem (e.g. no motion.csv) must not hide the verdict
            checks.append(check("replay count", NOT_RUN, f"replay failed: {e}"))
    return checks


def analyse_session(folder, truth):
    manifest = m1.load_manifest(folder)
    start, end = m1.session_bounds(manifest, folder)
    s = {"folder": str(folder), "sessionId": manifest.get("sessionId", Path(folder).name),
         "athlete": manifest.get("athlete") or "?", "recovered": bool(manifest.get("recovered"))}
    if start is None:
        s.update(minutes=0.0, ignored="no data")
        return s
    s["minutes"] = (end - start) / 60_000
    s["thermal"] = thermal_worst(folder)
    s["tornRows"] = m1.torn_rows(folder)

    cues = m1.cue_delivery(m1.read_rows(Path(folder) / "cues.csv"))
    s["mark1"] = {"ok": m1.cues_ok(manifest, cues, start, end),
                  "detail": f"{cues['delivered']}/{cues['issued']} = {cues['percent']:.1f}% delivered"}

    bat = m1.battery_at(m1.read_rows(Path(folder) / "battery.csv"), start, end, minutes=m1.BATTERY_MINUTES)
    if not bat["known"]:
        s["mark2"] = {"status": FAIL, "detail": "no battery readings"}
    elif bat["start_percent"] < m1.BATTERY_START_MIN:
        s["mark2"] = {"status": NOT_RUN, "detail": f"battery start {bat['start_percent']:.0f}% < {m1.BATTERY_START_MIN:.0f}%: mark not comparable"}
    elif not bat["reached"]:
        # Ended before 90 min: a battery that is flat, or on course to be under the mark, is the failure this mark exists to catch.
        gone = bat["last_percent"] <= BATTERY_FLAT
        low = bat["percent"] < m1.BATTERY_MARK and bat["session_minutes"] >= BATTERY_PROJECT_MIN_MINUTES
        text = (f"session {bat['session_minutes']:.0f} min, 90 not reached, last {bat['last_percent']:.0f}%, "
                f"projected {bat['percent']:.0f}% at 90 min")
        s["mark2"] = {"status": FAIL if gone or low else NOT_RUN,
                      "detail": text + (" (battery ran out)" if gone else
                                        "" if bat["session_minutes"] >= BATTERY_PROJECT_MIN_MINUTES else
                                        f" (under {BATTERY_PROJECT_MIN_MINUTES} min: too short to project)")}
    else:
        s["mark2"] = {"status": PASS if bat["percent"] >= m1.BATTERY_MARK else FAIL,
                      "detail": f"{bat['percent']:.0f}% at 90 min (start {bat['start_percent']:.0f}%)"}

    parts, hz_ok = m1.motion_check(folder, start, end)
    s["mark3"] = {"ok": hz_ok, "detail": "; ".join(parts)}
    s["checks"] = coached_checks(folder, manifest, truth)
    return s


def mark_status(ok_list):
    return PASS if all(ok_list) else FAIL


def verdict(sessions, min_minutes, data_dir):
    used = [s for s in sessions if "ignored" not in s and s["minutes"] >= min_minutes]
    ignored = [s for s in sessions if s not in used]
    marks = {}

    fails = [s for s in used if not s["mark1"]["ok"]]
    marks[1] = ({"status": NOT_RUN, "reasons": ["no sessions"]} if not used else
                {"status": FAIL if fails else PASS,
                 "reasons": [f"{s['sessionId']} ({s['athlete']}): {s['mark1']['detail']}" for s in (fails or used)]})

    reached = [s for s in used if s["mark2"]["status"] in (PASS, FAIL)]
    bad = [s for s in reached if s["mark2"]["status"] == FAIL]
    if bad:
        marks[2] = {"status": FAIL, "reasons": [f"{s['sessionId']}: {s['mark2']['detail']}" for s in bad]}
    elif reached:
        marks[2] = {"status": PASS, "reasons": [f"{s['sessionId']}: {s['mark2']['detail']}" for s in reached]}
    else:
        marks[2] = {"status": NOT_RUN, "reasons": ["no comparable session (start >= 95%) reached 90 minutes"]
                    + [f"{s['sessionId']}: {s['mark2']['detail']}" for s in used]}

    fails = [s for s in used if not s["mark3"]["ok"]]
    marks[3] = ({"status": NOT_RUN, "reasons": ["no sessions"]} if not used else
                {"status": FAIL if fails else PASS,
                 "reasons": [f"{s['sessionId']}: {s['mark3']['detail']}" for s in (fails or used)]})

    groups = m1.athlete_minutes([s["folder"] for s in used])
    athletes = {a: g for a, g in groups.items() if a != "?"}
    reasons, ok = [], True
    if len(athletes) < MIN_ATHLETES:
        ok = False
        reasons.append(f"{len(athletes)} athlete code(s) ({', '.join(sorted(athletes)) or 'none'}); need {MIN_ATHLETES}")
    if REQUIRED_ATHLETE not in athletes:
        ok = False
        reasons.append(f"no sessions for {REQUIRED_ATHLETE}")
    for a in sorted(athletes):
        missing = m1.missing_activities(athletes[a]["minutes"])
        if missing:
            ok = False
            reasons.append(f"{a} missing {', '.join(missing)}")
        else:
            reasons.append(f"{a}: all 10 activities")
    if "?" in groups:
        reasons.append("sessions with no athlete code are not counted")
    marks[4] = {"status": PASS if ok else FAIL, "reasons": reasons}

    coached_fail = [(s["sessionId"], c) for s in used for c in s.get("checks", []) if c["status"] == FAIL]
    all_pass = all(m["status"] == PASS for m in marks.values())
    return {"dataDir": str(data_dir), "overall": PASS if all_pass else FAIL, "marks": marks,
            "coachedFailures": [f"{sid}: {c['name']}: {c['detail']}" for sid, c in coached_fail],
            "sessions": used, "ignored": [{"sessionId": s["sessionId"], "reason": s.get("ignored") or f"under {min_minutes:g} min"} for s in ignored]}


MARK_NAMES = {1: "Cue delivery >= 95%", 2: "Battery >= 30% at 90 min", 3: "Motion >= 50 Hz for 95% of seconds",
              4: ">= 3 athletes incl. A1, all 10 activities"}


def render_text(v):
    out = [f"M1 gym-day verdict: {v['overall']}   ({len(v['sessions'])} session(s) from {v['dataDir']})", ""]
    for n in (1, 2, 3, 4):
        m = v["marks"][n]
        out.append(f"Mark {n}  {m['status']:<8} {MARK_NAMES[n]}")
        out += [f"    {r}" for r in m["reasons"]]
    out.append("")
    out.append("Sessions:")
    for s in v["sessions"]:
        flags = []
        if s["recovered"]:
            flags.append("recovered")
        if s.get("thermal"):
            flags.append(f"thermal worst {s['thermal']}")
        out.append(f"  {s['sessionId']}  {s['athlete']}  {s['minutes']:.0f} min" + (f"  [{', '.join(flags)}]" if flags else ""))
        if s.get("tornRows"):
            out.append("     " + m1.torn_note(s["tornRows"]))
        out.append(f"     1 {PASS if s['mark1']['ok'] else FAIL}: {s['mark1']['detail']}")
        out.append(f"     2 {s['mark2']['status']}: {s['mark2']['detail']}")
        out.append(f"     3 {PASS if s['mark3']['ok'] else FAIL}: {s['mark3']['detail']}")
    if v["ignored"]:
        out.append("Ignored: " + "; ".join(f"{i['sessionId']} ({i['reason']})" for i in v["ignored"]))
    out += ["", "Coached checks (not M1 gates):"]
    coached = [(s, c) for s in v["sessions"] for c in s.get("checks", [])]
    out += [f"  {s['sessionId']}  {c['name']} {c['status']}: {c['detail']}" for s, c in coached] or ["  none (no coach.json)"]
    return "\n".join(out)


def render_md(v):
    out = [f"# M1 gym-day verdict: {v['overall']}", "", "| Mark | Result | Why |", "|---|---|---|"]
    for n in (1, 2, 3, 4):
        m = v["marks"][n]
        out.append(f"| {n}. {MARK_NAMES[n]} | {m['status']} | {'<br>'.join(m['reasons'])} |")
    out += ["", "## Sessions", ""]
    for s in v["sessions"]:
        out.append(f"- `{s['sessionId']}` {s['athlete']}, {s['minutes']:.0f} min"
                   + (f", thermal worst {s['thermal']}" if s.get("thermal") else "") + (", recovered" if s["recovered"] else "")
                   + (f", {sum(s['tornRows'].values())} malformed row(s) skipped" if s.get("tornRows") else ""))
    out += ["", "## Coached checks (not M1 gates)", ""]
    out += [f"- `{s['sessionId']}` {c['name']}: {c['status']} ({c['detail']})" for s in v["sessions"] for c in s.get("checks", [])] or ["- none"]
    if v["ignored"]:
        out += ["", "Ignored: " + "; ".join(f"`{i['sessionId']}` ({i['reason']})" for i in v["ignored"])]
    return "\n".join(out) + "\n"


def usage_error(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def parse_truth(items):
    out = {}
    for item in items or []:
        key, _, val = item.rpartition("=")
        if not key or not val.isdigit() or int(val) <= 0:
            usage_error(f"--wb-truth wants <session>=<positive count>, got {item!r}")
        out[key] = int(val)
    return out


def resolve_truth(truth, folders):
    """Map each --wb-truth key to exactly one session id (exact match, else a unique prefix). Exit 2 otherwise."""
    ids = [m1.load_manifest(f).get("sessionId", f.name) for f in folders]
    resolved = {}
    for key, n in truth.items():
        hits = [i for i in ids if i == key] or [i for i in ids if i.startswith(key)]
        if len(hits) != 1:
            usage_error(f"--wb-truth {key}: " + ("matches no session" if not hits else f"matches {len(hits)} sessions ({', '.join(hits)})")
                             + f"; sessions found: {', '.join(ids)}")
        folder = next(f for f, i in zip(folders, ids) if i == hits[0])
        if not (Path(folder) / "coach.json").exists():
            usage_error(f"--wb-truth {key}: session {hits[0]} has no coach.json (an uncoached recording has no wall-ball count to compare)")
        resolved[hits[0]] = n
    return resolved


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data_dir")
    ap.add_argument("--wb-truth", action="append", metavar="SESSION=N", help="true wall-ball count for a coached session (id or id prefix)")
    ap.add_argument("--json", metavar="FILE")
    ap.add_argument("--md", metavar="FILE")
    ap.add_argument("--min-minutes", type=float, default=10.0, help="ignore sessions shorter than this (default 10)")
    args = ap.parse_args(argv)
    truth = parse_truth(args.wb_truth)
    folders = find_sessions(args.data_dir)
    if not folders:
        print(f"no sessions under {args.data_dir}")
        return 2
    truth = resolve_truth(truth, folders)
    sessions = []
    for f in folders:
        sid = m1.load_manifest(f).get("sessionId", f.name)
        sessions.append(analyse_session(f, truth.get(sid)))
    v = verdict(sessions, args.min_minutes, args.data_dir)
    print(render_text(v))
    if args.json:
        Path(args.json).write_text(json.dumps(v, indent=2) + "\n")
    if args.md:
        Path(args.md).write_text(render_md(v))
    return 0 if v["overall"] == PASS else 1


if __name__ == "__main__":
    sys.exit(main())
