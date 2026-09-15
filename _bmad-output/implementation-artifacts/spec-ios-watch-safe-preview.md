---
id: IOS-WATCH-01
title: Add the read-only Watch Safe Preview
status: backlog
github_issue: https://github.com/achappell/hermes-relay-ios/issues/69
---

# IOS-WATCH-01 — Watch Safe Preview

## Scope

Expose one small read-only preview of the current Hermes task or session on
Apple Watch.

## Acceptance

- One bounded Safe Preview may be shown; later updates are transcript/status
  only.
- Watch cannot open a remote desktop, capture audio, use the microphone, or
  replay hidden content.
- Revocation and disconnect remove access without mutating the active
  conversation.
- Watch has no independent Profile, Session, or authorization authority.

## Dependencies

Home HOME-NW-02, HOME-NW-03, and HOME-NW-06.
