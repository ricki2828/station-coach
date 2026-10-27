"""Red-flag patterns, vendored and cut down from an earlier internal coach service (see README).

The debrief takes no free text (D8), so nothing an athlete says reaches this service. `detect` is used on the model's own
reply as a validator rule: medical language in a facts-only debrief is a failure (repair once, then refuse), never a reason
to show emergency copy. `template` is kept for a future free-text version and is not sent by any route today.
Everyday debrief words ("pace collapsed", "short of breath") are NOT in the hard list. English only.
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
    r"(?:nearly|almost|about to)\s+(?:faint\w*|pass(?:ed)?\s+out|black(?:ed)?\s+out)",
    r"faint(?:ed|ing)\b", r"pass(?:ed|ing)?\s+out", r"black(?:ed)\s+out", r"lost\s+consciousness",
    r"palpitation\w*", r"arm\s+(?:went\s+|is\s+|was\s+|felt\s+)?numb", r"numb\s+(?:left\s+)?arm",
    r"heat\s*stroke",
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
