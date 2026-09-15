---
id: IOS-HOME-01
title: Add the iOS Home pairing and configuration adapter
status: backlog
github_issue: https://github.com/achappell/hermes-relay-ios/issues/68
---

# IOS-HOME-01 — Home pairing adapter

## Scope

Connect iOS Device administration to Home enrollment and the revisioned
Room/Wake Mapping configuration contract.

## Acceptance

- Discovery shows an unconfigured Device separately and never grants access by
  discovery alone.
- Trusted approval supplies an opaque Device credential and ordered Room, Wake
  Mapping, and Ready configuration.
- Secure storage, expected-revision writes, stale conflicts, unavailable
  state, expiry, revocation, and re-enrollment are explicit.
- iOS consumes Home arbitration results and does not implement a second
  configuration or arbitration authority.

## Dependencies

Home HOME-NW-02 and the existing iOS Epic 3 administration stories.
