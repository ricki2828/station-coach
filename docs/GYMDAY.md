# Gym day: from recordings to an M1 verdict

Python 3 and numpy, on the host. Recordings hold heart rate: keep them in `~/station-coach-data`, outside this repository (`ingest.py` refuses to write inside it), and never commit them.

```
python3 tools/ingest.py ~/Downloads/*.zip --into ~/station-coach-data
python3 tools/gymday.py ~/station-coach-data --wb-truth <sessionId>=20 --md verdict.md --json verdict.json
python3 tools/desk_check.py ~/station-coach-data/A1/<sessionId>
```

## ingest
Unzips (or copies) every session it finds and files it as `<athlete>/<sessionId>/`. It checks that every file in `manifest.files` exists and is not empty, that CSV headers match `FORMAT.md`, and that `coach.json` parses. A session with no `files` list never finished and is skipped. A sessionId already filed is skipped as a duplicate (re-running is safe). Exit code 1 if anything other than a duplicate was skipped.

## gymday
The exit code is 0 only when all four marks PASS and no coached check FAILs. Sessions under `--min-minutes` (default 10) are ignored and listed.

| Mark | Rule |
|---|---|
| 1 Cues | Every session: >= 95% of cues spoken to headphones and finished (interval sessions also need 90% of the expected cues issued). |
| 2 Battery | >= 30% at 90 min, in every session that started at >= 95% and reached 90 min. A start below 95% is flagged "mark not comparable". With no comparable session that reached 90 minutes the mark is NOT RUN, and the verdict is not PASS. |
| 3 Motion | Every session: median stored rate >= 50 Hz and >= 95% of session seconds at >= 50 Hz, for accel and motion. |
| 4 Coverage | At least 3 athlete codes including A1, each with all 10 activities across their sessions. |

Coached sessions (`coach.json`) also get these checks, and a FAIL fails the verdict:
- finish cue: the last cue issued has a `finished` row.
- splits: every plan step has an end, or the session is `early`.
- phantom reps: counted reps outside the wall-ball steps.
- wall-ball count: the watch's uncorrected count against `--wb-truth <sessionId or prefix>=N`, +-5%. Without the flag it prints the count and is NOT RUN (not a failure).
- If `tools/wallball_replay.py` exists, its replayed count is printed beside the watch's (information only).

The worst `thermal` state from `events.csv` is printed per session (the watch logs it once the recovery work lands; older sessions show none).

## desk_check
PASS, FAIL or NOT RUN per check on one folder: mode=speech, a `BluetoothA2DPOutput` route, "headphones lost" followed by "reactivating: headphones back" and cues resuming, `rates.csv` rows every minute, no "Could not start". Run it on the session recorded after a force-quit. NOT RUN means the test was not done in that session.

## Not verified
Nothing here has run against a real recording; the fixtures are synthetic. Thresholds are the M1 marks in `m1_report.py`.
