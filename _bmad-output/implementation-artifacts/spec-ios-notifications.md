---
id: IOS-NOTIFY-01
title: Add opt-in iOS notifications and quiet hours
status: backlog
github_issue: https://github.com/achappell/hermes-relay-ios/issues/71
---

# IOS-NOTIFY-01 — Notifications

## Scope

Deliver endpoint-scoped iOS notifications without interfering with an active
conversation.

## Acceptance

- Categories and quiet hours are independently configurable for the iOS
  endpoint.
- Notification delivery never creates a turn, changes a Profile, or interrupts
  active audio or capture.
- Revocation and expiry stop future delivery.
- Notification content follows the Home permission and safe-content policy.

## Dependencies

Home HOME-NW-02, HOME-NW-10, and the iOS Home pairing adapter.
