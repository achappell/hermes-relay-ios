---
story: 0-I-4
run_id: 20260914-140556-e55a
status: blocked
phase: plan
---

# Story 0-I-4 validation record

## Outcome

The migrated unattended BMad auto loop generated the Story 4 implementation
plan, then paused at the plan checkpoint after the read-only spec reviewer
returned `fail`. No implementation, focused XCTest, simulator build/test,
macOS build/test, or live smoke check ran.

## Blocking dependency

Home Story 2 must first publish the approved Apple-facing bridge contract. The
current upstream material leaves the endpoint path and versioned envelope open,
and does not yet pin the handle exchange, route/Household identity, readiness
and safe-error states, Standard event mapping, or route-loss behavior. Story 4
must select that single contract before an Apple adapter can be implemented.

## Review evidence

The plan reviewer recorded 16 blocking findings. They fall into these required
repair groups:

- one authoritative Home/Standard route, with route/session/Household identity
  and no route change during active or uncertain delivery;
- versioned device-credential conversion with crash-safe verification and
  explicit legacy rollback;
- Apple-owned configuration, readiness, heartbeat/reconnect, lifecycle, and
  typed failure boundaries;
- a defined Standard/Home-to-normalized-event mapping and dual-socket join
  state machine;
- verified PCM metadata, audio-unavailable behavior, interrupt confirmation,
  optional prompt/command capability handling, and explicit timing absence;
- phase-specific route-loss recovery and persistence of the uncertainty marker;
- a pinned Hermes release and focused XCTest command, followed by corrected
  iOS/macOS build and manual evidence commands.

The reviewer also identified that the existing manual plan describes an older
project/scheme, bearer-token form, `hello_ack`, and same-socket audio flow, so it
cannot be used as Story 4 evidence until the migration contract is pinned and
the Apple validation steps are updated.

## Resume condition

Re-arm the story only after Home Story 2 resolves the bridge endpoint/envelope,
identity, capability, and failure decisions and the local Story 4 spec is
repaired against them. Then run the auto loop’s plan review again before any
implementation attempt. Preserve the explicit rollback and fresh-user-action
boundary; do not invent a direct Standard or Home endpoint in this repository.

## Evidence safety

This record contains no prompts, response text, credentials, raw protocol
frames, PCM bytes, microphone captures, or screenshots.
