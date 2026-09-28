"""Fixed-window rate limit per caller, shared across Cloud Run instances through Firestore.

A per-process counter would let N instances each allow the full budget. The window counter is
one Firestore document per (caller, window) incremented in a transaction; a Firestore TTL policy
on `expire_at` deletes old windows, so the collection does not grow."""

from __future__ import annotations

import hashlib
import time
from datetime import datetime, timedelta, timezone
from typing import Protocol


class CounterStore(Protocol):
    def incr(self, key: str, expire_at: datetime) -> int: ...


class MemoryStore:
    """For unit tests and local runs."""

    def __init__(self) -> None:
        self.counts: dict[str, int] = {}

    def incr(self, key: str, expire_at: datetime) -> int:  # noqa: ARG002
        self.counts[key] = self.counts.get(key, 0) + 1
        return self.counts[key]


class FirestoreStore:
    def __init__(self, client, collection: str = "ratelimit"):
        from google.cloud import firestore

        self._fs, self._col = firestore, client.collection(collection)
        self._client = client

    def incr(self, key: str, expire_at: datetime) -> int:
        ref = self._col.document(key)
        firestore = self._fs

        @firestore.transactional
        def _txn(txn):
            snap = ref.get(transaction=txn)
            count = (snap.to_dict() or {}).get("count", 0) + 1
            txn.set(ref, {"count": count, "expire_at": expire_at})
            return count

        return _txn(self._client.transaction())


class RateLimiter:
    def __init__(
        self, store: CounterStore, limit: int, window_s: int = 60, clock=time.time
    ):
        self.store, self.limit, self.window_s, self.clock = (
            store,
            limit,
            window_s,
            clock,
        )

    def check(self, email: str) -> tuple[bool, int]:
        """Returns (allowed, seconds_until_the_window_resets)."""
        now = self.clock()
        window = int(now // self.window_s)
        key = f"{hashlib.sha256(email.encode()).hexdigest()[:16]}-{window}"
        expire = datetime.fromtimestamp(
            (window + 2) * self.window_s, tz=timezone.utc
        ) + timedelta(minutes=5)
        count = self.store.incr(key, expire)
        return count <= self.limit, int((window + 1) * self.window_s - now) + 1
