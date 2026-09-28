# 0004 — Rate limiting is shared state in Firestore

Cloud Run scales to several instances; a per-process counter would give each instance the full budget. The limiter keeps one Firestore document per (caller, minute window), incremented in a transaction, with an `expire_at` field covered by a Firestore **TTL policy** so old windows delete themselves.

Fixed windows allow a burst of up to twice the limit across a window boundary; that is accepted for simplicity. Cost: one transaction (a read and a write) per request. Over the limit → HTTP 429 with `Retry-After`. The limit is per caller, so a runaway agent cannot starve the operator (`test §6`).
