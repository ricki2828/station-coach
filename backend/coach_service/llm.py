"""The model sits behind this interface. The default provider is a stub: no key, no network."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


class NotConfigured(Exception):
    pass


class ProviderError(Exception):
    pass


@dataclass(frozen=True)
class LlmResult:
    text: str
    cost_usd: float = 0.0


class LlmProvider(Protocol):
    def complete(self, system: str, user: str) -> LlmResult: ...


class StubProvider:
    def complete(self, system: str, user: str) -> LlmResult:
        raise NotConfigured("no model provider is configured")
