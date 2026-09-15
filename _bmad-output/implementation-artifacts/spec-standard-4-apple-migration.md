---
id: STD-4
title: Migrate the Apple client to the Standard Home boundary
status: backlog
github_issue: https://github.com/achappell/hermes-relay-ios/issues/67
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
