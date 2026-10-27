"""The facts schema. It is the whole payload: unknown fields are rejected at every depth and there is no free text."""
from __future__ import annotations

import datetime as dt
import re
import uuid
from enum import Enum
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator

Secs = Annotated[int, Field(ge=0, le=36000, strict=True)]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Activity(str, Enum):
    run = "run"
    transition = "transition"
    skierg = "skierg"
    sled_push = "sled_push"
    sled_pull = "sled_pull"
    burpee_broad_jump = "burpee_broad_jump"
    row = "row"
    farmers_carry = "farmers_carry"
    sandbag_lunges = "sandbag_lunges"
    wall_balls = "wall_balls"
    rest = "rest"


class SessionType(str, Enum):
    full_sim = "full_sim"
    half_sim = "half_sim"
    wall_ball_focus = "wall_ball_focus"


class Division(str, Enum):
    open_men = "open_men"
    open_women = "open_women"
    pro_men = "pro_men"
    pro_women = "pro_women"


class Reference(str, Enum):
    plan = "plan"
    ghost = "ghost"


class Step(Strict):
    activity: Activity
    targetSeconds: Secs
    actualSeconds: Secs | None = None   # absent for a skipped step, never 0
    skipped: StrictBool
    quit: StrictBool | None = None      # started and abandoned when the session ended early; never completed

    @model_validator(mode="after")
    def _actual_iff_done(self):
        if self.skipped and self.quit:
            raise ValueError("a step is skipped or quit, not both")
        not_done = self.skipped or bool(self.quit)
        if not_done and self.actualSeconds is not None:
            raise ValueError("a skipped or quit step carries no actualSeconds")
        if not not_done and self.actualSeconds is None:
            raise ValueError("actualSeconds is required unless the step was skipped or quit")
        return self


class WallBalls(Strict):
    reps: Annotated[int, Field(ge=0, le=500, strict=True)]
    noReps: Annotated[int, Field(ge=0, le=500, strict=True)]
    setSizes: list[Annotated[int, Field(ge=0, le=500, strict=True)]] = Field(max_length=60)
    restSeconds: list[Annotated[int, Field(ge=0, le=3600, strict=True)]] = Field(max_length=60)


_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class CoachFacts(Strict):
    consentVersion: Annotated[int, Field(ge=1, strict=True)]
    installId: uuid.UUID
    date: str
    sessionType: SessionType
    division: Division
    raceTargetSeconds: Secs
    totalSeconds: Secs
    plannedSeconds: Secs
    early: StrictBool
    steps: list[Step] = Field(max_length=40)
    wallBalls: WallBalls | None = None
    fadeSeconds: Annotated[int, Field(ge=-3600, le=3600, strict=True)] | None = None
    reference: Reference | None = None
    referenceDeltaSeconds: Annotated[int, Field(ge=-36000, le=36000, strict=True)] | None = None

    @field_validator("installId", mode="before")
    @classmethod
    def _uuid_str(cls, v):
        # strict mode refuses str -> UUID; the wire form is a string
        if isinstance(v, str):
            return uuid.UUID(v)
        raise ValueError("installId must be a UUID string")

    @field_validator("date")
    @classmethod
    def _day_only(cls, v: str) -> str:
        if not _DAY.match(v):
            raise ValueError("date must be YYYY-MM-DD (day precision)")
        dt.date.fromisoformat(v)
        return v


class RegisterRequest(Strict):
    installId: uuid.UUID
    consentVersion: Annotated[int, Field(ge=1, strict=True)]
    attestation: str | None = Field(default=None, max_length=6000)   # App Attest / DeviceCheck blob

    @field_validator("installId", mode="before")
    @classmethod
    def _uuid_str(cls, v):
        if isinstance(v, str):
            return uuid.UUID(v)
        raise ValueError("installId must be a UUID string")
