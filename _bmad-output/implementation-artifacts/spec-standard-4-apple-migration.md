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
control also works. This 2026-09-21 live result is the evidence basis for
Amanda's acceptance of STD-4/0-I-4. The separate IOS-HOME-07 validation is
contextual only; none of that story's device or slow-turn gates are accepted,
changed, or waived by this closeout.

The earlier `public_adapter_unavailable` finding (a synthetic-credential
listener probe answered `status: unavailable`, `reason: hermes_unavailable`)
and the environment-blocked `-HomeBridgeFake` walkthrough are historical and
superseded; see the validation record.

## Acceptance record — 2026-10-07

Amanda accepted STD-4 (alias 0-I-4) as `done` on 2026-10-07.

- **Accepted evidence:** the 2026-09-21 live Home `conversation.open` result
  (`Home bridge Ready`, `Approved route reachable`, voice control confirmed by
  Amanda). On owner decision, this evidence supersedes the uncompleted
  `-HomeBridgeFake` walkthrough for this migration story only.
- **Scope:** this closes only STD-4/0-I-4. IOS-HOME-07's device and slow-turn
  gates remain unchanged and unwaived; this acceptance does not close or waive
  any IOS-HOME-07 criterion.
- **Superseded, not run:** the manual `-HomeBridgeFake` fake-bridge walkthrough
  was never completed. On owner decision, live Home evidence is accepted in its
  place. No fake walkthrough scenario is marked passed.
- **Test-run scope:** owner acceptance relied on evidence already recorded; it
  did not require a new migration, device, or Home test run. PR #130 later adds
  only test-queue synchronization, with no app behavior or acceptance-evidence
  change; its focused verification is reported in the PR.
- **Issue #67:** left open by this change; it can be closed after this record
  merges.
