"""Reply rules for the debrief (design spec section 4). Written for this service; the idea (ground every figure in the
source facts, refuse and repair once) follows an earlier internal coach service. A failing reply is never shown."""
from __future__ import annotations

import re
import unicodedata

from .prompt import STATION_NAMES
from .schema import CoachFacts

NEXT_SESSIONS = ("Full sim", "Half sim", "Wall-ball focus")
PRAISE = ("great", "well done", "awesome", "amazing", "nice work", "good job", "fantastic", "brilliant", "excellent",
          "crushed it", "smashed it", "killed it", "incredible")
# Built from pieces so the public repo never spells the brand out.
BANNED_TERMS = ("hy" + "rox", "iron" + "man", "spartan race")
_NUM = re.compile(r"\d+(?::\d{2}){1,2}|\d+")
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def fmt(sec: int) -> str:
    sec = abs(int(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _times(sec: int) -> set[str]:
    sec = abs(int(sec))
    out = {str(sec), fmt(sec)}
    if sec % 60 == 0:
        out.add(str(sec // 60))   # "20 minutes"
    return out


def allowed_numbers(f: CoachFacts) -> set[str]:
    secs: list[int] = [f.raceTargetSeconds, f.totalSeconds, f.plannedSeconds]
    secs.append(f.totalSeconds - f.plannedSeconds)
    for st in f.steps:
        if st.skipped:
            continue   # a skipped step has no time to quote
        secs += [st.targetSeconds, st.actualSeconds, st.actualSeconds - st.targetSeconds]
    if f.fadeSeconds is not None:
        secs.append(f.fadeSeconds)
    if f.referenceDeltaSeconds is not None:
        secs.append(f.referenceDeltaSeconds)
    allowed: set[str] = set()
    for s in secs:
        allowed |= _times(s)
    counts: list[int] = [len(f.steps), sum(1 for s in f.steps if s.skipped)]
    if f.wallBalls:
        w = f.wallBalls
        counts += [w.reps, w.noReps, len(w.setSizes), *w.setSizes, *w.restSeconds, w.reps - w.noReps]
        for r in w.restSeconds:
            allowed |= _times(r)
    allowed |= {str(c) for c in counts}
    allowed |= {str(int(d)) for d in f.date.split("-")}   # a day-of-month or year is a fact too
    return allowed


def check(reply: str, f: CoachFacts, max_words: int = 90) -> str | None:
    """None if the reply passes, else a short reason (fed back to the model once as a repair note)."""
    text = (reply or "").strip()
    if not text:
        return "it was empty"
    if len(text.split()) > max_words:
        return f"it was longer than {max_words} words"
    if any(unicodedata.category(c) in ("So", "Cs") or ord(c) > 0x1F000 for c in text):
        return "it contained an emoji or symbol"
    low = text.lower()
    if any(t in low for t in BANNED_TERMS):
        return "it named an event or brand"
    sentences = [s for s in _SENTENCE_END.split(text) if s]
    if not _NUM.search(sentences[0]):
        return "the first sentence had no number from the session"
    allowed = allowed_numbers(f)
    for tok in _NUM.findall(text):
        if tok not in allowed:
            return f"the figure {tok} is not in the session facts"
    for s in sentences:
        if any(p in s.lower() for p in PRAISE) and not _NUM.search(s):
            return "it praised without a number"
    names = {STATION_NAMES[a].lower() for a in STATION_NAMES}
    named = {n for n in names if n != "rest" and re.search(r"\b" + re.escape(n) + r"\b", low)}
    if len(named) != 1:
        return "it must name exactly one station or run"
    last = sentences[-1]
    nxt = [n for n in NEXT_SESSIONS if n.lower() in low]
    if len(nxt) != 1 or nxt[0].lower() not in last.lower():
        return "it must end with exactly one next session: Full sim, Half sim or Wall-ball focus"
    if f.early:
        if re.search(r"\b(target|on plan|planned|on pace|projected)\b", low) or fmt(f.raceTargetSeconds) in text \
                or fmt(f.plannedSeconds) in text:
            return "the session ended early, so do not compare the total to the target or plan"
    return None
