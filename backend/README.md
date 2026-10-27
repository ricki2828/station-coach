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
  free text. The install ID and consent version are not passed to the model. A skipped step carries no `actualSeconds`
  (absent, never 0) and its numbers cannot be quoted.
- **Day-precision dates (D11).** `date` is `YYYY-MM-DD`; a time of day is a 422. Server timestamps are stored as days too.
- **30-day retention, delete on turn-off (D9).** Every request purges first, and `python -m coach_service.purge` does the
  same from cron. It removes sessions, devices idle for 30 days, and install IDs on spend rows (the cost stays for the
  month total). `DELETE /v1/data` removes sessions, consent and token at once.
- **Spend control.** Reserve the worst case (two model calls) before calling; settle the real cost, including when the
  repair turn errors. Limits: per-device daily count (default 3), a global daily USD ceiling, a monthly USD cap. Monthly
  cap and daily ceiling default to **0, which refuses everything**, whatever the per-call estimate.
- **Registration limits.** New installs are limited per client address and in total per day, and a known install ID can
  only be re-registered with its current token (otherwise 409), so a leaked ID cannot take over an install.
- **Attestation hook.** `/v1/register` passes the phone's `attestation` blob to an `Attestor`. The default fails closed;
  `COACH_DEV_MODE=1` accepts anything for local development. No Apple verification is written.
- **Reply rules.** At most 90 words; first sentence has a number from the facts; exactly one station or run named; ends
  with one next session (Full sim, Half sim, Wall-ball focus); no praise without a number; no emojis; no event or brand
  names; no number that isn't in the facts or a difference of two of them; medical language is refused; an `early` session
  is never compared to the target or plan. A failing reply gets one repair turn, then a 502. It is never returned.
- **No emergency copy on a debrief.** There is no free text, so a red-flag hit in the model's reply is a reply-rule
  failure, not a safety event. `redflag.template` is kept for a future free-text version and no route sends it.
- **The model sits behind `LlmProvider`.** The default is a stub that raises "not configured" (503). Tests use a fake.
- Bodies over 8 KB are refused (413).

## Run the tests
```
cd backend
pip install -r requirements-dev.txt
python -m pytest -q
```
CI runs the same in the `backend` job. No network is used.

## Vendored from an earlier internal coach service
Adapted, not imported, from a sibling coach service by the same owner (no cross-repo dependency):
`redflag.py` (pattern tiers and negation handling, cut to the hard-tier ideas and rewritten without country lines),
`budget.py` (reserve, settle, release; cut to a daily count and a monthly cap on SQLite), `prompt.py` (host-rules block
idea: facts are data, never claim a change was made), `validator.py` (ground every figure in the source, one repair turn;
rewritten for the debrief rules). No code is shared across repos at runtime.

## Deploy blockers (do not deploy before these)
1. **App Attest (or Sign in with Apple) in the `Attestor`.** Without it anyone can mint installs and spend the cap.
   The in-app limits above only bound the damage.
2. **Edge rate limit on `/v1/register` and `/v1/coach`, and proxy headers.** Behind a reverse proxy every client shares
   one per-address bucket unless uvicorn runs with `--proxy-headers --forwarded-allow-ips=<proxy address>`. A real limit
   must also live at the edge.
3. **`COACH_IP_SECRET`.** The address hash is an HMAC with this key; the service refuses to start without it unless
   `COACH_DEV_MODE=1`. Generate it on the host; it is not in the repo.
4. **One worker only.** The store is SQLite behind an in-process lock; spend checks use `BEGIN IMMEDIATE`, but nothing else
   is multi-process safe.

## Where this needs the owner before it can go live
1. **Repo location.** It lives in `backend/` of this public repo until he says otherwise.
2. **Hosting and deploy.** None chosen. `main.py` is a plain `uvicorn main:app` entry point; set `COACH_DB_PATH`,
   `COACH_MONTHLY_CAP_USD`, `COACH_DAILY_CEILING_USD`, `COACH_DAILY_LIMIT`.
3. **OpenRouter key and monthly cap.** No real provider class exists. Writing one needs the key and the cap, and
   zero-retention confirmed on the account (the consent copy changes if not, D10).
4. **Sign in with Apple and the App Attest app IDs.** The per-device daily cap can still be reset by reinstalling.
5. **Lawyer-approved consent text**, then bump `COACH_CONSENT_VERSION` if it changes.
6. **The feature flag.** Stays off in the phone app until he turns it on.

## Cases for the eval pass on real replies
Generic "run" counted as naming a second station; "the first 2 sets" (a count not in the facts); everyday exertion words the
medical-language rule lets through ("dizzy", "short of breath", "pace collapsed"), which must still read as ordinary debrief
text and carry no advice; a skipped station; an early session; a first-ever session with no history.

## Not covered
Backups, logging/monitoring, and any real model output. The reply rules are tested against scripted replies only: expect
a high refusal rate (for example a generic "run" counts as naming a station) until an eval pass on real replies.
