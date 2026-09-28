---
id: IOS-HOME-02
status: in-progress
product_epic: 1
created: 2026-09-23
---

# IOS-HOME-02 — Pair iOS and macOS personal clients with Home and manage sessions

## Approved scope

Consume Home pairing links/codes, store per-Home credentials in Keychain, handle Profile-owner approval and grants, renew/revoke, and manage authorized sessions. Record separate iOS and macOS setup, text, voice, stop and reconnect acceptance. Reuse IOS-HOME-01 room administration and STD-4 transport; those do not complete personal admission.

## Acceptance

- Deliver the owner-specific behavior above using unmodified Standard Hermes and the approved [delivery contract](course-correction-2026-09-23.md).
- Preserve existing story evidence and supported adapters; no automatic mode switch or replay of an uncertain turn.
- Record applicable setup, capability limits, privacy, failure and recovery behavior against the actual supported baseline.
- Record implementation, merge and physical/live acceptance separately; do not declare an unexercised gate complete.

## Dependencies

- home:HOME-NW-17

## Readiness

Delivered in slices. Slice 1, pair and connect through a client claim ([spec](spec-ios-home-02-pair-and-connect.md)), is merged with partial iOS live evidence; see [validation-ios-home-02.md](validation-ios-home-02.md). Still open, and required before this story closes (`deferred-work.md`): session management (list, resume, most-recent, new and rename Home client sessions, with `session_busy`/`session_unavailable` handling) and Profile-owner administration (pending grants, holders, revoke, unpair; [slice 3 spec](spec-ios-home-02-owner-administration.md), implemented and in review), plus the remaining iOS live checks and the macOS live gate. Each open slice needs its own specification and readiness review before implementation.
