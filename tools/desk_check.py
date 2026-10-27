#!/usr/bin/env python3
"""The PROTOCOL desk-test reads on one session folder, done for you.

    python3 tools/desk_check.py <session-folder> [<session-folder> ...]

Each check prints PASS, FAIL or NOT RUN (the test it needs was not done in that session). Exit code 1 if any
check FAILs. Checks follow docs/PROTOCOL.md "Desk test additions".
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import m1_report as m1  # noqa: E402

PASS, FAIL, NOT_RUN = "PASS", "FAIL", "NOT RUN"


def issued_cues(folder):
    return [r for r in m1.read_rows(Path(folder) / "cues.csv") if r["event"] == "issued"]


def speech_mode(folder):
    cues = issued_cues(folder)
    if not cues:
        return NOT_RUN, "no cues logged"
    bad = [r["cue_id"] for r in cues if r["mode"] != "speech"]
    return (FAIL, f"{len(bad)}/{len(cues)} cues not mode=speech (ids {', '.join(bad[:5])})") if bad else \
        (PASS, f"all {len(cues)} cues mode=speech")


def a2dp_output(folder):
    cues = issued_cues(folder)
    if not cues:
        return NOT_RUN, "no cues logged"
    n = sum("BluetoothA2DPOutput" in r["outputs"] for r in cues)
    return (PASS, f"{n}/{len(cues)} cues went out over BluetoothA2DPOutput") if n else \
        (FAIL, f"no cue went out over BluetoothA2DPOutput (outputs seen: {sorted({r['outputs'] for r in cues})})")


def headphones_lost_sequence(folder):
    events = [r for r in m1.read_rows(Path(folder) / "events.csv") if r["kind"] == "audio_mode"]
    lost = [r for r in events if "headphones lost" in r["detail"]]
    if not lost:
        return NOT_RUN, "no 'headphones lost' event: the AirPods-off test was not done in this session"
    first = int(lost[0]["epoch_ms"])
    back = [r for r in events if "reactivating: headphones back" in r["detail"] and int(r["epoch_ms"]) > first]
    if not back:
        return FAIL, "'headphones lost' logged but never 'reactivating: headphones back' afterwards"
    later = [r for r in issued_cues(folder) if int(r["epoch_ms"]) > int(back[0]["epoch_ms"])]
    if not later:
        return FAIL, "reactivated, but no cue was issued afterwards (cues did not resume)"
    return PASS, f"lost, reactivated {(int(back[0]['epoch_ms']) - first) / 1000:.0f} s later, {len(later)} cue(s) after"


def rates_every_minute(folder):
    manifest = m1.load_manifest(folder)
    if manifest.get("recovered"):
        return NOT_RUN, "this is the recovered (force-quit) session; run the check on the session recorded after it"
    start, end = m1.session_bounds(manifest, folder)
    if start is None:
        return NOT_RUN, "no data"
    minutes = int((end - start) // 60_000)
    if minutes < 2:
        return NOT_RUN, f"session is {minutes} min long"
    rows = m1.read_rows(Path(folder) / "rates.csv")
    short = []
    for stream in ("accel", "motion"):
        n = sum(r["stream"] == stream for r in rows)
        if n < minutes - 1:  # one minute of slack for the last, unflushed window
            short.append(f"{stream} {n}/{minutes}")
    return (FAIL, "rates.csv rows missing: " + ", ".join(short)) if short else \
        (PASS, f"rates.csv has a row per stream for each of {minutes} minutes")


def could_not_start(folder):
    hits = [r for r in m1.read_rows(Path(folder) / "events.csv") if "Could not start" in r["detail"] or "Could not start" in r["kind"]]
    return (FAIL, f"'Could not start' logged: {hits[0]['detail']}") if hits else (PASS, "no 'Could not start' in events.csv")


CHECKS = [("mode=speech", speech_mode), ("A2DP output", a2dp_output),
          ("headphones lost -> reactivated", headphones_lost_sequence),
          ("rates.csv every minute", rates_every_minute), ("no 'Could not start'", could_not_start)]


def run(folder):
    return [(name, *fn(folder)) for name, fn in CHECKS]


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    failed = False
    for folder in argv[1:]:
        print(f"{folder}  ({m1.load_manifest(folder).get('sessionId', '?')})")
        for name, status, detail in run(folder):
            failed |= status == FAIL
            print(f"  {status:<8} {name}: {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
