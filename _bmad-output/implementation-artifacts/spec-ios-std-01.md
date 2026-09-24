---
id: IOS-STD-01
status: backlog
product_epic: 2
created: 2026-09-23
---

# IOS-STD-01 — Offer explicit Standard-only setup on iOS and macOS

## Approved scope

Offer HomeBridge/Standard setup; authenticate directly to supported unmodified Standard with no Home dependency. Require typed streaming, private local history and honest recovery on both Apple platforms. Voice is optional until verified. Keep credentials/history separate and never auto-fallback.

## Acceptance

- Deliver the owner-specific behavior above using unmodified Standard Hermes and the approved [delivery contract](course-correction-2026-09-23.md).
- Preserve existing story evidence and supported adapters; no automatic mode switch or replay of an uncertain turn.
- Record applicable setup, capability limits, privacy, failure and recovery behavior against the actual supported baseline.
- Record implementation, merge and physical/live acceptance separately; do not declare an unexercised gate complete.

## Dependencies

- ios:IOS-HOME-02

## Readiness

Approved backlog scope. Owning BMAD specification/readiness review must settle API details and a bounded execution plan before implementation. No implementation or runtime acceptance is claimed.
