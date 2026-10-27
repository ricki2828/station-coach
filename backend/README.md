# Coach service

Facts in, one short AI debrief out. **Built and tested only: not deployed, no model provider, no keys.** The phone side
(C5) codes against `openapi.yaml`, which is the contract.

## What it does
- `POST /v1/register` records consent for a random install ID and returns a device token.
- `POST /v1/coach` takes the facts schema and returns one reply (90 words max).
- `DELETE /v1/data` turns the coach off and deletes everything held for that install.

## Rules enforced (each has a test)
- **Consent gate.** `consentVersion` must equal the server's current version or the answer is 403, checked before the
  facts are read. A request with no consent on record gets no model call and stores nothing (`tests/test_consent_gate.py`).
- **Facts only (D8).** Any field outside the schema, at any depth, is a 422. No heart rate, no sensor data, no names, no
  free text. The install ID and consent version are not passed to the model.
- **Day-precision dates (D11).** `date` is `YYYY-MM-DD`; a time of day is a 422.
- **30-day retention, delete on turn-off (D9).** Kept sessions are purged after 30 days; `DELETE /v1/data` removes
  sessions, consent and token at once.
- **Spend control.** Per-device daily count (default 3, UTC day) and one monthly USD cap, with reserve before the call
  and settle or release after. The monthly cap defaults to **0, which authorises no spend**.
- **Reply rules.** At most 90 words; first sentence has a number from the facts; exactly one station or run named; ends
  with one next session (Full sim, Half sim, Wall-ball focus); no praise without a number; no emojis; no event or brand
  names; no number that isn't in the facts or a difference of two of them; an `early` session is never compared to the
  target or plan. A failing reply gets one repair turn, then a 502. It is never returned.
- **Red flags.** There is no free text to scan, so the model's own reply is scanned. A hit replaces it with fixed safety
  copy (`kind: "safety"`) and no model words are shown.
- **The model sits behind `LlmProvider`.** The default is a stub that raises "not configured" (503). Tests use a fake.

## Run the tests
```
cd backend
pip install -r requirements-dev.txt
python -m pytest -q
```
CI runs the same in the `backend` job. No network is used.

## Vendored from Run Supreme
Adapted, not imported, from `companion-server/companion/coach/` in the Run Supreme repo (same owner):
`redflag.py` (pattern tiers and negation handling, cut to the hard-tier ideas and rewritten without country lines),
`budget.py` (reserve, settle, release; cut to a daily count and a monthly cap on SQLite), `prompt.py` (host-rules block
idea: facts are data, never claim a change was made), `validator.py` (ground every figure in the source, one repair turn;
rewritten for the debrief rules). No code is shared across repos at runtime.

## Where this needs Ricki before it can go live
1. **Repo location.** It lives in `backend/` of this public repo until he says otherwise.
2. **Hosting and deploy.** None chosen. `main.py` is a plain `uvicorn main:app` entry point; set `COACH_DB_PATH`,
   `COACH_MONTHLY_CAP_USD`, `COACH_DAILY_LIMIT`.
3. **OpenRouter key and monthly cap.** No real provider class exists. Writing one needs the key and the cap, and
   zero-retention confirmed on the account (the consent copy changes if not, D10).
4. **Sign in with Apple.** Today the device token is the only auth and the install ID is random, so the per-device daily
   cap can be reset by reinstalling. The monthly cap is the real spend limit until accounts exist. Also missing: rate
   limiting on `/v1/register`.
5. **Lawyer-approved consent text**, then bump `COACH_CONSENT_VERSION` if it changes.
6. **The feature flag.** Stays off in the phone app until he turns it on.

## Not covered
Concurrency beyond a single process (SQLite behind one lock), backups, logging/monitoring, and any real model output.
The reply rules are tested against scripted replies only; real replies will need an eval pass.
