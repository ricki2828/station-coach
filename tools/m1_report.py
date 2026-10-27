#!/usr/bin/env python3
"""Print the four M1 pass marks for one or more recorder session folders.

    python3 tools/m1_report.py <session-folder> [<session-folder> ...]

Pass marks (docs/FORMAT.md describes the files):
  1. speech cues heard on headphones for >= 95% of cues
  2. >= 30% battery left at 90 minutes
  3. motion recorded at >= 50 Hz for >= 95% of session seconds (gaps count as missing)
  4. labelled minutes per activity (all 10 activities present)

Needs only the stdlib and numpy.
"""
import csv
import json
import re
import sys
from pathlib import Path

import numpy as np

ACTIVITIES = [
    "run", "transition", "skierg", "sled_push", "sled_pull",
    "burpee_broad_jump", "row", "farmers_carry", "sandbag_lunges", "wall_balls",
]
CUE_MARK = 95.0
BATTERY_MARK = 30.0
HZ_MARK = 50.0
BATTERY_MINUTES = 90
BATTERY_START_MIN = 95.0  # a session that starts below this is not comparable with the 30%-at-90-min mark
MIN_ACTIVITY_MINUTES = 0.0  # an activity counts as present only above this many labelled minutes
COVERAGE_MARK = 0.95  # share of session seconds that must reach HZ_MARK
CUE_ISSUED_MARK = 0.90  # issued cues as a share of interval x duration


# Columns that must parse as numbers for a row to be usable (the first column is always a timestamp).
NUMERIC = {"cues.csv": ("cue_id",), "battery.csv": ("level",), "hr.csv": ("bpm",)}
TORN_FILES = ["labels.csv", "cues.csv", "battery.csv", "hr.csv", "accel.csv", "motion.csv", "rates.csv", "events.csv"]


def _number(text):
    try:
        float(text)
        return True
    except ValueError:
        return False


ROW_START = re.compile(r"^-?\d{9,}(,|$)")  # a data row begins with an epoch timestamp


def logical_lines(f):
    """Lines of an open CSV, with a quoted field that holds a newline kept as one record. A record with an odd
    number of quotes is continued on the next line unless that line starts like a new data row (an unterminated
    quote in a torn row must not swallow the rows after it). Yields (record, ok); ok is False for such a torn record."""
    buf = None
    for raw in f:
        line = raw.rstrip("\r\n")
        if buf is not None:
            if ROW_START.match(line):
                yield buf, False  # the open quote was a torn row, not a multi-line field
                buf = None
            else:
                buf += "\n" + line
                if buf.count('"') % 2 == 0:
                    yield buf, True
                    buf = None
                continue
        if line.count('"') % 2:
            buf = line
        else:
            yield line, True
    if buf is not None:
        yield buf, False


def parse_csv(path):
    """(rows as dicts, number of skipped rows). A row is skipped when it is short or long for the header or a
    timestamp / numeric column does not parse: after a crash-resume a torn row can sit mid-file, not only at
    the end. Quoted fields with newlines are one row."""
    p = Path(path)
    if not p.exists():
        return [], 0
    rows, skipped = [], 0
    with p.open(newline="", errors="replace") as f:
        lines = logical_lines(f)
        header = next(csv.reader([next(lines, ("", True))[0]]), [])
        numeric = [i for i, h in enumerate(header) if h in NUMERIC.get(p.name, ())]
        for line, whole in lines:
            if not line:
                continue
            fields = next(csv.reader([line]), [])
            if not whole or len(fields) != len(header) or not fields[0].strip().lstrip("-").isdigit() or not all(_number(fields[i]) for i in numeric):
                skipped += 1
                continue
            rows.append(dict(zip(header, fields)))
    return rows, skipped


def read_rows(path):
    return parse_csv(path)[0]


def timestamps(path):
    """(first column as floats, skipped rows) for the big motion CSVs, with the same skipping rule as parse_csv."""
    p = Path(path)
    if not p.exists():
        return np.array([]), 0
    out, skipped = [], 0
    with p.open(errors="replace") as f:
        ncols = f.readline().count(",") + 1
        for line in f:
            line = line.rstrip("\r\n")
            if not line:
                continue
            first, _, _ = line.partition(",")
            if line.count(",") + 1 != ncols or not first.lstrip("-").isdigit():
                skipped += 1
                continue
            out.append(float(first))
    return np.array(out), skipped


def torn_rows(folder):
    """{file name: skipped row count} for the session's CSVs, only those with any."""
    out = {}
    for name in TORN_FILES:
        path = Path(folder) / name
        n = timestamps(path)[1] if name in ("accel.csv", "motion.csv") else parse_csv(path)[1]
        if n:
            out[name] = n
    return out


def torn_note(torn):
    return "skipped malformed rows (torn by a crash?): " + ", ".join(f"{k} {v}" for k, v in sorted(torn.items()))


def load_manifest(folder):
    p = Path(folder) / "manifest.json"
    return json.loads(p.read_text()) if p.exists() else {}


def cue_delivery(rows):
    """Same rule as CoachKit's CueLog.stats: every issued cue is in the denominator; it counts
    only if spoken to headphones, the synth reported finish, and it was not flagged missed."""
    by_id = {}
    for r in rows:
        by_id.setdefault(r["cue_id"], []).append(r)
    issued = delivered = haptic_only = missed = on_route = finished = any_route = 0
    modes = set()
    for events in by_id.values():
        first = next((e for e in events if e["event"] == "issued"), None)
        if first is None:
            continue
        issued += 1
        modes.add(first.get("audio_mode") or "?")
        if first["headphones"] == "1":
            on_route += 1
        kinds = {e["event"] for e in events}
        if "finished" in kinds:
            finished += 1
        if "missed" in kinds:
            missed += 1
        if first["mode"] == "speech" and "finished" in kinds and "missed" not in kinds:
            any_route += 1
        if first["mode"] == "haptic_only":
            haptic_only += 1
            continue
        if first["headphones"] == "1" and "finished" in kinds and "missed" not in kinds:
            delivered += 1
    pct = 100.0 * delivered / issued if issued else 0.0
    return {"issued": issued, "delivered": delivered, "haptic_only": haptic_only,
            "missed": missed, "percent": pct, "route_headphones": on_route, "finished": finished, "any_route": any_route,
            "audio_modes": sorted(modes)}


def session_bounds(manifest, folder):
    start = manifest.get("startedAtEpochMs")
    end = manifest.get("endedAtEpochMs")
    if start is None or end is None:
        stamps = []
        for name in ("battery", "labels", "cues", "hr"):
            stamps += [int(r["epoch_ms"]) for r in read_rows(Path(folder) / f"{name}.csv")]
        if not stamps:
            return None, None
        start = start if start is not None else min(stamps)
        end = end if end is not None else max(stamps)
    return int(start), int(end)


def battery_at(rows, start_ms, end_ms, minutes=BATTERY_MINUTES):
    """Level (percent) at `minutes` into the session, or the last reading and a linear projection."""
    pts = [(int(r["epoch_ms"]), float(r["level"])) for r in rows if float(r["level"]) >= 0]
    if not pts:
        return {"known": False}
    pts.sort()
    start_level = pts[0][1] * 100
    target = start_ms + minutes * 60_000
    last_t, last_level = pts[-1][0], pts[-1][1] * 100
    out = {"known": True, "start_percent": start_level, "last_percent": last_level,
           "session_minutes": (end_ms - start_ms) / 60_000}
    if last_t >= target - 30_000:
        t, level = min(pts, key=lambda p: abs(p[0] - target))
        out.update(reached=True, percent=level * 100)
    else:
        mins = (last_t - pts[0][0]) / 60_000
        drain = (start_level - last_level) / mins if mins > 0 else 0.0
        out.update(reached=False, drain_per_min=drain,
                   percent=start_level - drain * minutes)
    return out


def achieved_hz(path):
    """Median samples-per-second over whole seconds of the stored stream, and the overall mean rate."""
    p = Path(path)
    if not p.exists():
        return None
    ts, _ = timestamps(p)
    if ts.size < 2:
        return None
    secs = (ts - ts[0]) / 1e6
    span = secs[-1]
    if span <= 0:
        return None
    counts = np.bincount(secs.astype(np.int64))
    full = counts[:-1] if counts.size > 1 else counts  # last second is partial
    median = float(np.median(full)) if full.size else float(ts.size)
    return {"samples": int(ts.size), "mean_hz": float((ts.size - 1) / span), "median_hz": median}


def motion_coverage(path, start_ms, end_ms, mark=HZ_MARK):
    """Share of the manifest's whole seconds (start to end) holding >= `mark` samples, and the longest
    run of seconds below it. A stream that stops early, or never starts, counts as missing."""
    p = Path(path)
    total = max(1, int((end_ms - start_ms) // 1000))
    counts = np.zeros(total, dtype=np.int64)
    if p.exists():
        ts, _ = timestamps(p)
        if ts.size:
            secs = np.floor(ts / 1e6 - start_ms / 1000.0).astype(np.int64)
            secs = secs[(secs >= 0) & (secs < total)]
            counts = np.bincount(secs, minlength=total)
    good = counts >= mark
    longest = run = 0
    for g in good:
        run = 0 if g else run + 1
        longest = max(longest, run)
    return {"coverage": float(good.mean()), "longest_gap_s": int(longest), "seconds": total}


def expected_cues(manifest, start_ms, end_ms):
    interval = manifest.get("cueIntervalSec") or 0
    return int(((end_ms - start_ms) / 1000) // interval) if interval > 0 else 0


def missing_activities(minutes):
    """The activities, of the 10, with no more than MIN_ACTIVITY_MINUTES labelled (absent counts as 0).
    One rule for the per-session line and the per-athlete summary."""
    return [a for a in ACTIVITIES if minutes.get(a, 0.0) <= MIN_ACTIVITY_MINUTES]


def label_minutes(rows, start_ms, end_ms):
    """Replay set/undo events (set pushes, undo pops) into minutes per activity."""
    stack = []
    for r in sorted(rows, key=lambda r: int(r["epoch_ms"])):
        t = int(r["epoch_ms"])
        if r["event"] == "set":
            if not stack or stack[-1][0] != r["activity"]:
                stack.append((r["activity"], t))
        elif r["event"] == "undo" and stack:
            stack.pop()
    minutes = {}
    for i, (act, t) in enumerate(stack):
        nxt = stack[i + 1][1] if i + 1 < len(stack) else end_ms
        minutes[act] = minutes.get(act, 0.0) + max(0, nxt - t) / 60_000
    labelled = sum(minutes.values())
    total = (end_ms - start_ms) / 60_000
    minutes["_unlabelled"] = max(0.0, total - labelled)
    return minutes


def athlete_minutes(folders):
    """Per athlete code (sessions with no code are '?'): session count, wrists, labelled minutes per activity."""
    groups = {}
    for folder in folders:
        manifest = load_manifest(folder)
        start, end = session_bounds(manifest, folder)
        if start is None:
            continue
        g = groups.setdefault(manifest.get("athlete") or "?", {"sessions": 0, "wrists": set(), "minutes": {}})
        g["sessions"] += 1
        g["wrists"].add(manifest.get("wrist") or "?")
        for act, mins in label_minutes(read_rows(Path(folder) / "labels.csv"), start, end).items():
            if act in ACTIVITIES:
                g["minutes"][act] = g["minutes"].get(act, 0.0) + mins
    return groups


def athlete_summary(folders):
    """Labelled minutes per activity, grouped by the manifest's athlete code (sessions with no code
    are grouped as '?'). Needs all 10 activities per athlete to count as covered."""
    groups = athlete_minutes(folders)
    lines = ["Per athlete (labelled minutes, all sessions):"]
    for athlete in sorted(groups):
        g = groups[athlete]
        missing = missing_activities(g["minutes"])
        lines.append(f"  {athlete}: {g['sessions']} session(s), wrist {'/'.join(sorted(g['wrists']))}, "
                     f"{sum(g['minutes'].values()):.1f} min labelled, "
                     + ("all 10 activities" if not missing else "missing " + ", ".join(missing)))
        lines.append("     " + "  ".join(f"{a}={g['minutes'].get(a, 0.0):.1f}" for a in ACTIVITIES))
    return lines


def motion_check(folder, start, end):
    """(description parts, ok) for mark 3 over the accel and motion streams of one session."""
    folder = Path(folder)
    hz_parts, hz_ok = [], True
    for stream in ("accel", "motion"):
        r = achieved_hz(folder / f"{stream}.csv")
        if r is None:
            hz_parts.append(f"{stream} none")
            hz_ok = False
        else:
            cov = motion_coverage(folder / f"{stream}.csv", start, end)
            hz_parts.append(f"{stream} {r['median_hz']:.0f} Hz median ({r['mean_hz']:.1f} mean, {r['samples']} samples), "
                            f"{100 * cov['coverage']:.1f}% of session seconds >= {HZ_MARK:.0f} Hz, longest gap {cov['longest_gap_s']} s")
            hz_ok = hz_ok and r["median_hz"] >= HZ_MARK and cov["coverage"] >= COVERAGE_MARK
    return hz_parts, hz_ok


def cues_ok(manifest, cues, start, end):
    """Mark 1 for one session: enough delivered, and (interval sessions) enough issued."""
    expected = expected_cues(manifest, start, end)
    coached = manifest.get("cueIntervalSec") == 0
    issued_share = cues["issued"] / expected if expected else 1.0
    return cues["issued"] > 0 and cues["percent"] >= CUE_MARK and (coached or issued_share >= CUE_ISSUED_MARK)


def flag(ok):
    return "PASS" if ok else "FAIL"


def report(folder):
    folder = Path(folder)
    manifest = load_manifest(folder)
    start, end = session_bounds(manifest, folder)
    lines = [f"Session {manifest.get('sessionId', folder.name)}  athlete {manifest.get('athlete', '?')}  "
             f"wrist {manifest.get('wrist', '?')}  audio mode {manifest.get('audioMode', '?')}"]
    if start is None:
        return lines + ["  no data"]
    lines.append(f"  device {manifest.get('device', '?')}  os {manifest.get('osVersion', '?')}  "
                 f"motion api {manifest.get('motionApi', '?')}  length {(end - start) / 60_000:.1f} min")
    torn = torn_rows(folder)
    if torn:
        lines.append("  " + torn_note(torn))

    cues = cue_delivery(read_rows(folder / "cues.csv"))
    expected = expected_cues(manifest, start, end)
    coached = manifest.get("cueIntervalSec") == 0
    issued_share = cues["issued"] / expected if expected else 1.0
    mark1 = cues_ok(manifest, cues, start, end)
    lines.append(f"1. Cue delivery: {cues['delivered']}/{cues['issued']} = {cues['percent']:.1f}% "
                 f"(route showed headphones {cues['route_headphones']}, haptic-only {cues['haptic_only']}, "
                 f"flagged missed {cues['missed']}, audio mode {'/'.join(cues['audio_modes']) or '?'})  "
                 f"{flag(mark1)} (mark {CUE_MARK:.0f}%)")
    tap_rate = 100.0 * cues["missed"] / cues["issued"] if cues["issued"] else 0.0
    lines.append(f"   synth finished {cues['finished']}; athlete flagged 'didn't hear' {cues['missed']} ({tap_rate:.0f}% tap rate)"
                 + ("; no taps, so 'delivered' means the synth finished, NOT confirmed heard" if not cues["missed"] else ""))
    lines.append(f"   finished and not flagged, any route: {cues['any_route']}/{cues['issued']} "
                 f"(a gap from the mark above means the route read is unreliable or speech ran on the speaker)")
    if coached:
        lines.append(f"   cues issued {cues['issued']}; periodic cue check not applicable (coached session: "
                     f"cues follow the plan, so there is no interval to expect). Few cues make one miss cost "
                     f"{100 / max(cues['issued'], 1):.1f} points.")
    else:
        lines.append(f"   cues issued {cues['issued']} of ~{expected} expected "
                     f"({100 * issued_share:.0f}%, need {100 * CUE_ISSUED_MARK:.0f}%)")

    bat = battery_at(read_rows(folder / "battery.csv"), start, end)
    if not bat["known"]:
        lines.append("2. Battery at 90 min: no readings  FAIL")
    elif bat["reached"]:
        lines.append(f"2. Battery at 90 min: {bat['percent']:.0f}% (start {bat['start_percent']:.0f}%)  "
                     f"{flag(bat['percent'] >= BATTERY_MARK)} (mark {BATTERY_MARK:.0f}%)")
    else:
        lines.append(f"2. Battery at 90 min: not reached, session {bat['session_minutes']:.0f} min, "
                     f"last {bat['last_percent']:.0f}% (start {bat['start_percent']:.0f}%), "
                     f"projected {bat['percent']:.0f}% at {bat['drain_per_min']:.2f}%/min  "
                     f"{flag(bat['percent'] >= BATTERY_MARK)} projected (mark {BATTERY_MARK:.0f}%)")

    if bat.get("known") and bat["start_percent"] < BATTERY_START_MIN:
        lines.append(f"   battery start {bat['start_percent']:.0f}% < {BATTERY_START_MIN:.0f}%: mark not comparable")
    hz_parts, hz_ok = motion_check(folder, start, end)
    raw = [r for r in read_rows(folder / "rates.csv") if r.get("raw_hz")]
    if raw:
        best = max(float(r["raw_hz"]) for r in raw)
        hz_parts.append(f"raw peak {best:.0f} Hz")
    lines.append(f"3. Motion rate (stored): {'; '.join(hz_parts)}  {flag(hz_ok)} (mark {HZ_MARK:.0f} Hz)")

    mins = label_minutes(read_rows(folder / "labels.csv"), start, end)
    missing = missing_activities(mins)
    lines.append("4. Labelled minutes:")
    for a in ACTIVITIES + ["rest"]:
        lines.append(f"     {a:<20}{mins.get(a, 0.0):7.1f}")
    lines.append(f"     {'(unlabelled)':<20}{mins['_unlabelled']:7.1f}")
    lines.append(f"   {flag(not missing)} all 10 activities in this session"
                 + (f" (missing: {', '.join(missing)})" if missing else ""))
    return lines


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for i, folder in enumerate(argv[1:]):
        if i:
            print()
        print("\n".join(report(folder)))
    print()
    print("\n".join(athlete_summary(argv[1:])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
