"""Who may call what. The map lives in the CALLERS_JSON env var (rendered by Terraform), so the
set of principals and their scopes is reviewed in a PR, never edited at runtime."""

from __future__ import annotations

import json
from dataclasses import dataclass

SCOPES = {"ops:read", "notes:read", "notes:write"}


@dataclass(frozen=True)
class Caller:
    email: str
    scopes: frozenset[str]


class Policy:
    def __init__(self, callers: dict[str, list[str]]):
        for email, scopes in callers.items():
            unknown = set(scopes) - SCOPES
            if unknown:
                raise ValueError(f"{email}: unknown scope(s) {sorted(unknown)}")
        self._callers = {e.lower(): frozenset(s) for e, s in callers.items()}

    @classmethod
    def from_json(cls, raw: str) -> Policy:
        data = json.loads(raw or "{}")
        if not isinstance(data, dict):
            raise ValueError("CALLERS_JSON must be an object of email -> [scopes]")
        return cls(data)

    def lookup(self, email: str) -> Caller | None:
        scopes = self._callers.get(email.lower())
        return None if scopes is None else Caller(email.lower(), scopes)
