---
id: IOS-RETIRE-01
status: backlog
product_epic: 4
created: 2026-09-23
---

# IOS-RETIRE-01 — Remove legacy Apple pairing and fork integration

## Approved scope

Inventory/remove obsolete pairing UI, fork adapters, settings, fixtures and docs. Preserve supported Standard adapters and intentional history. Contribute signed iOS/macOS acceptance evidence to Home migration Story 9; signed macOS distribution remains MACOS-DIST-F1.

## Acceptance

- Deliver the owner-specific behavior above using unmodified Standard Hermes and the approved [delivery contract](course-correction-2026-09-23.md).
- Preserve existing story evidence and supported adapters; no automatic mode switch or replay of an uncertain turn.
- Record applicable setup, capability limits, privacy, failure and recovery behavior against the actual supported baseline.
- Record implementation, merge and physical/live acceptance separately; do not declare an unexercised gate complete.

## Dependencies

- ios:IOS-HOME-02
- ios:IOS-STD-01

## Readiness

Approved backlog scope. Owning BMAD specification/readiness review must settle API details and a bounded execution plan before implementation. No implementation or runtime acceptance is claimed.
