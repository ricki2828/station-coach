"""Red-flag escalation, vendored and cut down from run-solo companion/coach/redflag.py (see README).

Run Supreme scans what the runner types. This service takes no free text (D8), so the only text to scan is what the
model writes. If the reply touches a red-flag topic the model's text is dropped and the fixed safety copy goes out
instead; no model words are shown. The patterns lean towards false positives on purpose. English only.
"""
from __future__ import annotations

import re
import unicodedata

URGENT = "urgent"
WELLBEING = "wellbeing"

_CHEST = r"(?:chest|sternum)"
_URGENT = [
    _CHEST + r"\W*(?:pain|pains|tight\w*|pressure|hurt\w*|ache\w*|squeez\w*|discomfort)",
    r"(?:pain|tightness|pressure|crush\w*|squeez\w*)\s+(?:\w+\s+){0,3}" + _CHEST,
    r"(?:nearly|almost|about to)\s+(?:faint\w*|pass(?:ed)?\s+out|black(?:ed)?\s+out|collaps\w*)",
    r"faint(?:ed|ing)\b", r"pass(?:ed|ing)?\s+out", r"black(?:ed)\s+out", r"collaps(?:e|ed|ing)\b", r"lost\s+consciousness",
    r"palpitation\w*", r"arm\s+(?:went\s+|is\s+|was\s+|felt\s+)?numb", r"numb\s+(?:left\s+)?arm",
    r"heat\s*stroke", r"dizz\w*", r"light\s*-?\s*headed\w*", r"short(?:ness)?\s+of\s+breath",
]
_WELLBEING = [
    r"kill(?:ing)?\s+my\s*self", r"suicid\w*", r"self[\s-]*harm\w*", r"(?:hurt|harm|cut)(?:ting)?\s+my\s*self",
    r"end(?:ing)?\s+my\s+life", r"want\s+to\s+die", r"better\s+off\s+(?:dead|without\s+me)", r"hopeless", r"worthless",
]
URGENT_RE = re.compile("|".join(f"(?:{p})" for p in _URGENT), re.I)
WELLBEING_RE = re.compile("|".join(f"(?:{p})" for p in _WELLBEING), re.I)
_NEGATION = re.compile(r"\b(?:no|never|without)\s+(?:any\s+)?$", re.I)


def _norm(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text or "").replace("’", "'").split())


def _hit(rx: re.Pattern, text: str) -> bool:
    return any(not _NEGATION.search(text[max(0, m.start() - 24):m.start()]) for m in rx.finditer(text))


def detect(text: str) -> str | None:
    t = _norm(text)
    if _hit(WELLBEING_RE, t):
        return WELLBEING
    if _hit(URGENT_RE, t):
        return URGENT
    return None


def template(kind: str) -> str:
    """Fixed copy. Facts carry no location, so no country-specific lines: only 'your local' numbers."""
    if kind == URGENT:
        return ("If you had chest pain, dizziness, fainting or trouble breathing, stop training and get checked by a doctor today. "
                "If it is happening now or it is bad, call your local emergency number straight away. "
                "No training advice from the coach until you have been checked.")
    return ("Training can wait. If you are struggling, please talk to someone you trust or contact your local crisis line today. "
            "If you are in danger right now, call your local emergency number.")
