---
id: STD-4
title: Migrate the Apple client to the Standard Home boundary
status: review
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

Home HOME-NW-01, HOME-NW-02, and HOME-NW-03. The story remains blocked until
the endpoint-facing Home bridge is live, even though its contract is pinned.

## Current evidence

The owning local story is implemented and its deterministic Apple gates are
ready for review. Production Apple code is constrained to Home's planned
schema-1 `/api/v1/bridge/ws` boundary, with Device authorization, one reader,
opaque Home handles, typed prompt/command actions, strict audio joining, and
explicit uncertainty recovery. Vanilla Hermes endpoints remain rollback-only
and are not opened by Home mode.

The deployed listener answered a schema-1 `conversation.open` probe with
`status: unavailable` and `reason: hermes_unavailable` when given a
deliberately synthetic Device credential. No real credential or turn was sent,
so the public Home adapter is recorded as `public_adapter_unavailable`. The
fake UI smoke is also environment blocked because the available computer-use
surface could not attach to the iOS Simulator window.
