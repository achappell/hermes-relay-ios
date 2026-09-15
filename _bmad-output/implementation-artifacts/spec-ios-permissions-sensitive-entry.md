---
id: IOS-PERM-01
title: Enforce iOS endpoint permissions and masked Sensitive Entry
status: backlog
github_issue: https://github.com/achappell/hermes-relay-ios/issues/70
---

# IOS-PERM-01 — Permissions and Sensitive Entry

## Scope

Implement the iOS presentation and secure-storage side of endpoint-scoped
permissions and masked sensitive input.

## Acceptance

- Capability categories are shown per endpoint and risky actions require
  explicit confirmation.
- Sensitive values are masked and never enter transcript, Local History, Watch
  preview, or ordinary diagnostics.
- Stale, revoked, expired, and denied grants fail closed.
- Route changes and reconnects cannot widen Home authority or replay an action.

## Dependencies

Home HOME-NW-10 and IOS-HOME-01.
