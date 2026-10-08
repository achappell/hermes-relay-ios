---
id: STD-4
title: Migrate the Apple client to the Standard Home boundary
status: done
github_issue: https://github.com/achappell/hermes-relay-ios/issues/67
local_story: next-wave-standard-hermes-migration/stories/0-I-4-apple-migrate-ios-macos-client.md
validation: next-wave-standard-hermes-migration/stories/validation-0-I-4-apple-migrate-ios-macos-client.md
---

# STD-4 — Apple migration

## Scope

Move the iOS/macOS client from the fork route to the paired Home bridge and
pinned Standard Hermes boundary without changing the established doorway.

## Acceptance

- The client uses an approved Home route and opaque Device credential; the
  Hermes bearer remains server-side.
- Profile identity, Local History, text/audio phases, interruption, lifecycle,
  and no-replay recovery survive migration.
- Standard JSON, PCM, prompt correlation, reconnect, and timing behavior are
  validated; timing is explicit when absent.
- The fork remains rollback-only until the cross-surface retirement gate.

## Dependencies

Home HOME-NW-01, HOME-NW-02, and HOME-NW-03. These were the gate for live
evidence. The endpoint-facing Home bridge is now served, and the live evidence
below was recorded against it.

## Current evidence

The owning local story is implemented. Production Apple code is constrained to
Home's schema-1 `/api/v1/bridge/ws` boundary, with Device authorization, one
reader, opaque Home handles, typed prompt/command actions, strict audio
joining, and explicit uncertainty recovery. Vanilla Hermes endpoints remain
rollback-only and are not opened by Home mode. Deterministic Apple gates are
recorded in the validation record.

Live Home evidence (2026-09-21, recorded in the validation record): after the
managed Home bridge task was restarted, the approved route returned HTTP 401 to
an unauthenticated probe. The Relay then completed a live `conversation.open`
handshake with a securely provisioned Device credential and reported
`Home bridge Ready` and `Approved route reachable`. Amanda confirmed that voice
control also works. The IOS-HOME-07 validation record
(`validation-ios-home-07.md`) also records live Home traffic on 2026-10-04: a
turn that Home and Standard accepted was not delivered because the client's
30 s control-terminal deadline fired first. The deadline was raised to 120 s
under fake-clock regressions; on-device confirmation of that fix was still
open in that record and is not claimed here.

The earlier `public_adapter_unavailable` finding (a synthetic-credential
listener probe answered `status: unavailable`, `reason: hermes_unavailable`)
and the environment-blocked `-HomeBridgeFake` walkthrough are historical and
superseded; see the validation record.

## Acceptance record — 2026-10-07

Amanda accepted STD-4 (alias 0-I-4) as `done` on 2026-10-07.

- **Accepted evidence:** the live Home `conversation.open` result of
  2026-09-21 (`Home bridge Ready`, voice control confirmed by Amanda) and the
  live Home evidence in `validation-ios-home-07.md`, together with the
  deterministic Apple gates already recorded. The evidence was accepted as
  recorded, including the open on-device item above.
- **Superseded, not run:** the manual `-HomeBridgeFake` fake-bridge walkthrough
  was never completed. On owner decision, live Home evidence is accepted in its
  place. No fake walkthrough scenario is marked passed.
- **No new test run:** this closeout is a documentation and status change. It
  did not run builds, tests, device checks, or Home traffic.
- **Issue #67:** left open by this change; it can be closed after this record
  merges.
