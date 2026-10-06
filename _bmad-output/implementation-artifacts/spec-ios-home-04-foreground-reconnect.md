---
title: 'IOS-HOME-04: Home reconnects after a long background'
type: 'bugfix'
created: '2026-10-04'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After the iPhone app spent more than two minutes in the background (deployed Home 082e593, HOME-NW-18), it stayed "Disconnected · transport_unavailable" and could not reconnect to Home. Home recorded no refusal: the app's single foreground connect attempt failed at the transport layer and was never retried. Scene-phase Tasks can also interleave, so a stale deactivate can undo a newer activate. Separately, a `stale_conversation` refusal on reconnect is treated as final, while the open path already replaces the claim.

**Approach:** (1) Handle scene-phase inputs serially in `AppleLifecycleCoordinator`, so a deactivate that is already superseded cannot close a newer activation's client or lifecycle. (2) When an open or reconnect fails with `transport_unavailable` or `transport_timeout` while the lifecycle is active, retry with the existing `reconnectPolicy` and deadlines, reusing the kept claim. Retries stop on background, disconnect, or profile change, and unconfirmed prompts are never replayed. (3) A reconnect refused with `stale_conversation` and no pending recovery releases the old claim where possible and opens a fresh claim, as the open path does, in both `reconnectHome` and `runHomeReconnectLoop`.

</frozen-after-approval>

## Implementation Notes

- Test first: the three regression tests failed against main 66477da, then passed after the fix (see `validation-ios-home-04.md`).
- `AppleLifecycleCoordinator.handle` runs scene-phase requests in order through a chained task. When a newer request is already queued, an older one is skipped. The phase that wins is the newest one SwiftUI reported.
- `ConversationStore`: `connect()` now starts a fresh retry budget and calls the private `performConnect()`. When an open or reconnect fails with `transport_unavailable` or `transport_timeout` (outside the lifecycle phase), `scheduleHomeConnectRetry` reopens the held claim. It uses the `reconnectPolicy` delays, clamped to `homeOperationDeadlines.reconnectOverall`. Disconnect, lifecycle deactivation, profile change, and stale generations all cancel the retry. A retry never resubmits a prompt.
- The open-path claim replacement was extracted into `replaceEndedHomeClaim` and is reused by `reconnectHome`. `runHomeReconnectLoop` releases the claim, then calls `performConnect()`. Both happen only for `stale_conversation` with no `homeRecovery`.
- Test support: the echo fake in `HomeClientPairingTests` can now script open and reconnect outcomes, and `InstantPairingTestClock` was added. `AppleLifecycleTests` gained a slow-persistence fixture option.

## Review Triage Log

- Superseded lifecycle requests return `.completed` without running: false. Only the newest phase matters; a skipped inactive followed by an active correctly leaves the bridge live (covered by the test).
- Retry task not cleared when the sleep throws: false. Sleep throws only on cancellation, and `cancelHomeConnectRetry` already clears the task.
- Retry wake time not bounded by the overall deadline: low. Patched by clamping the wake time to `reconnectOverall`.
- `.reconnecting` can be left showing after a cancelled retry: low. Patched so that cancelling a pending retry returns the state to `.disconnected`.
- Missing tests for each stop condition: low, rejected. Disconnect stop and transport_timeout are covered. Lifecycle and profile change rely on the same generation and cancel checks that IOS-HOME-03 already tests.
