"""Device attestation hook (App Attest / DeviceCheck). Only the interface exists: no Apple verification is written.

`/v1/register` passes the phone's `attestation` string and the install ID here. The default verifier fails closed;
`COACH_DEV_MODE=1` accepts anything, for local development only. A real verifier needs the app's team and bundle IDs,
which are not set up. See README: this is a deploy blocker.
"""
from __future__ import annotations

from typing import Protocol


class Attestor(Protocol):
    def verify(self, install_id: str, attestation: str | None) -> bool: ...


class FailClosedAttestor:
    def __init__(self, dev_mode: bool = False):
        self.dev_mode = dev_mode

    def verify(self, install_id: str, attestation: str | None) -> bool:
        return self.dev_mode
