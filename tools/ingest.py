#!/usr/bin/env python3
"""File exported session zips/folders under a data directory, one folder per athlete and session.

    python3 tools/ingest.py <zip|folder> [<zip|folder> ...] [--into ~/station-coach-data]

Each input may be a session zip from the phone's Raw files, a session folder, or a folder (or zip) that
holds several sessions. Every session found is validated against docs/FORMAT.md (the files its manifest
lists exist and are not empty, the CSV headers match, coach.json parses) and filed as
`<into>/<athlete>/<sessionId>/`. A sessionId already filed is skipped, so re-running is safe.
Recordings hold heart rate: the data directory must be outside this repository.
"""
import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_INTO = Path("~/station-coach-data").expanduser()
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")

HEADERS = {
    "labels.csv": "epoch_ms,event,activity",
    "cues.csv": "epoch_ms,cue_id,event,mode,headphones,outputs,phrase,detail,audio_mode",
    "battery.csv": "epoch_ms,level,state",
    "hr.csv": "epoch_ms,bpm",
    "accel.csv": "epoch_us,x,y,z",
    "motion.csv": "epoch_us,ua_x,ua_y,ua_z,rr_x,rr_y,rr_z,g_x,g_y,g_z",
    "rates.csv": "epoch_ms,stream,raw_samples,raw_hz,stored_samples,stored_hz",
    "events.csv": "epoch_ms,kind,detail",
}


def safe_extract(archive, dest):
    """Unzip, refusing any member that would land outside `dest` (zip-slip)."""
    root = dest.resolve()
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            target = (dest / info.filename).resolve()
            if target != root and root not in target.parents:
                raise ValueError(f"unsafe path in zip: {info.filename}")
        z.extractall(dest)


def find_sessions(root):
    """Folders under `root` (or root itself) that hold a manifest.json, ignoring macOS zip litter."""
    return sorted(p.parent for p in root.rglob("manifest.json") if "__MACOSX" not in p.parts)


def validate(folder):
    """Return (manifest, problems). No problems means the session is fit to file."""
    problems = []
    try:
        manifest = json.loads((folder / "manifest.json").read_text())
    except (OSError, ValueError) as e:
        return {}, [f"manifest.json unreadable ({e})"]
    sid = manifest.get("sessionId")
    if not isinstance(sid, str) or not SAFE.match(sid):
        problems.append(f"bad sessionId {sid!r}")
    athlete = manifest.get("athlete")
    if athlete is not None and not (isinstance(athlete, str) and SAFE.match(athlete)):
        problems.append(f"bad athlete code {athlete!r}")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        problems.append("manifest lists no files (the session never finished)")
        files = []
    for name in files:
        p = folder / name if isinstance(name, str) and "/" not in name and not name.startswith(".") else None
        if p is None:
            problems.append(f"bad file name {name!r} in manifest")
        elif not p.is_file():
            problems.append(f"{name} listed in manifest but missing")
        elif p.stat().st_size == 0:
            problems.append(f"{name} is empty")
    for name, header in HEADERS.items():
        p = folder / name
        if p.is_file() and p.stat().st_size:
            with p.open(errors="replace") as f:
                first = f.readline().strip()
            if first != header:
                problems.append(f"{name} header is {first!r}, expected {header!r}")
    coach = folder / "coach.json"
    if coach.is_file():
        try:
            data = json.loads(coach.read_text())
            if not isinstance(data, dict) or "plan" not in data or "splits" not in data:
                problems.append("coach.json lacks plan/splits")
        except ValueError as e:
            problems.append(f"coach.json does not parse ({e})")
    return manifest, problems


def ingest(inputs, into):
    """File every valid session from `inputs` under `into`. Returns (filed, skipped) lists of strings."""
    into = Path(into).expanduser().resolve()
    if into == REPO or REPO in into.parents:
        raise SystemExit(f"refusing to write recordings inside the repository ({into}); pick a directory outside it")
    filed, skipped = [], []
    with tempfile.TemporaryDirectory(prefix="sc-ingest-") as tmp:
        sources = []
        for i, item in enumerate(inputs):
            p = Path(item).expanduser()
            if p.is_dir():
                sources.append((str(p), p))
            elif zipfile.is_zipfile(p):
                dest = Path(tmp) / str(i)
                dest.mkdir()
                try:
                    safe_extract(p, dest)
                except (ValueError, zipfile.BadZipFile) as e:
                    skipped.append(f"{p}: {e}")
                    continue
                sources.append((str(p), dest))
            else:
                skipped.append(f"{p}: not a zip or a folder")
        for label, root in sources:
            found = find_sessions(root)
            if not found:
                skipped.append(f"{label}: no manifest.json inside")
            for folder in found:
                manifest, problems = validate(folder)
                name = f"{label} [{folder.name}]"
                if problems:
                    skipped.append(f"{name}: " + "; ".join(problems))
                    continue
                sid = manifest["sessionId"]
                dest = into / (manifest.get("athlete") or "unknown") / sid
                if any(into.glob(f"*/{sid}")):
                    skipped.append(f"{name}: duplicate sessionId {sid} already filed")
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(folder, dest)
                filed.append(f"{name} -> {dest}")
    return filed, skipped


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="session zips or folders")
    ap.add_argument("--into", default=str(DEFAULT_INTO), help=f"data directory (default {DEFAULT_INTO})")
    args = ap.parse_args(argv)
    filed, skipped = ingest(args.inputs, args.into)
    for line in filed:
        print("filed   ", line)
    for line in skipped:
        print("skipped ", line)
    print(f"{len(filed)} filed, {len(skipped)} skipped")
    # an already-filed duplicate is not a problem; anything else skipped is
    return 1 if any("duplicate sessionId" not in line for line in skipped) else 0


if __name__ == "__main__":
    sys.exit(main())
