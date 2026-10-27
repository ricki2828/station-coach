"""HTTP surface. Order of checks on /v1/coach: token (401), consentVersion (403), consent on record (403), schema (422),
cap (429), model. Nothing about the facts is read before the consent check passes."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Callable

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from . import budget, prompt, redflag, validator
from .config import Settings
from .llm import LlmProvider, NotConfigured, StubProvider
from .schema import CoachFacts, RegisterRequest
from .store import Store


def create_app(settings: Settings | None = None, provider: LlmProvider | None = None,
               clock: Callable[[], datetime] | None = None) -> FastAPI:
    s = settings or Settings.from_env()
    llm = provider or StubProvider()
    now = clock or (lambda: datetime.now(timezone.utc))
    store = Store(s.db_path)
    app = FastAPI(title="Station Coach coach service", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = store

    def err(status: int, code: str, **extra) -> JSONResponse:
        return JSONResponse({"error": code, **extra}, status_code=status)

    def consent_denied() -> JSONResponse:
        return err(403, "consent_required", currentConsentVersion=s.consent_version)

    async def json_body(request: Request):
        try:
            body = json.loads(await request.body())
        except ValueError:
            return None
        return body if isinstance(body, dict) else None

    def consent_ok(body: dict) -> bool:
        v = body.get("consentVersion")
        return isinstance(v, int) and not isinstance(v, bool) and v == s.consent_version

    def bearer(request: Request) -> str | None:
        h = request.headers.get("authorization", "")
        return h[7:] if h.lower().startswith("bearer ") and len(h) > 7 else None

    @app.post("/v1/register")
    async def register(request: Request):
        body = await json_body(request)
        if body is None:
            return err(422, "invalid_body")
        if not consent_ok(body):
            return consent_denied()
        try:
            req = RegisterRequest.model_validate(body)
        except ValidationError as e:
            return err(422, "invalid_body", detail=[x["loc"] for x in e.errors()])
        token = store.register(str(req.installId), req.consentVersion, now())
        return {"deviceToken": token}

    @app.post("/v1/coach")
    async def coach(request: Request):
        token = bearer(request)
        device = store.device_for_token(token) if token else None
        if device is None:
            return err(401, "unauthorized")
        body = await json_body(request)
        if body is None:
            return err(422, "invalid_body")
        if not consent_ok(body) or device["consent_version"] != s.consent_version:
            return consent_denied()
        try:
            facts = CoachFacts.model_validate(body)
        except ValidationError as e:
            return err(422, "invalid_body", detail=[[str(p) for p in x["loc"]] for x in e.errors()])
        install = str(facts.installId)
        if install != device["install_id"]:
            return err(403, "install_mismatch")

        t = now()
        store.purge_expired(t, s.retention_days)
        try:
            ledger_id = budget.reserve(store, s, install, t)
        except budget.Capped as c:
            return err(429, c.code)

        facts_json = facts.model_dump(mode="json", exclude_none=True)
        history = store.recent_sessions(install, s.history_sessions, 1 << 60)
        user = prompt.build_user(facts, history)

        reply, cost, reason = "", 0.0, "no attempt"
        try:
            for attempt in range(2):   # one repair turn, as in run-solo
                result = llm.complete(prompt.SYSTEM, user + (prompt.repair_note(reason) if attempt else ""))
                cost += result.cost_usd
                if redflag.detect(result.text):
                    store.settle(ledger_id, cost)
                    store.add_session(install, facts_json, t)
                    kind = redflag.detect(result.text)
                    return {"reply": redflag.template(kind), "kind": "safety",
                            "remainingToday": budget.remaining_today(store, s, install, t)}
                reason = validator.check(result.text, facts, s.max_reply_words)
                if reason is None:
                    reply = result.text.strip()
                    break
        except NotConfigured:
            store.release(ledger_id)
            return err(503, "not_configured")
        except Exception:   # provider failed: no charge recorded, nothing shown
            store.release(ledger_id)
            return err(503, "provider_error")
        store.settle(ledger_id, cost)
        if reason is not None:
            return err(502, "reply_rejected")   # nothing kept: the facts are not stored for a reply that never shipped
        store.add_session(install, facts_json, t)
        return {"reply": reply, "kind": "debrief", "remainingToday": budget.remaining_today(store, s, install, t)}

    @app.delete("/v1/data")
    async def delete_data(request: Request):
        token = bearer(request)
        device = store.device_for_token(token) if token else None
        if device is None:
            return err(401, "unauthorized")
        return {"deletedSessions": store.delete_install(device["install_id"])}

    return app
