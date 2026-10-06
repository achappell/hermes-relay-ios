---
title: 'IOS-HOME-06: Treat a backgrounded Home transport as disconnected'
type: 'bugfix'
created: '2026-10-04'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The pilot iPhone was backgrounded for about two minutes. Home 082e593 parked claim `2pE5lS` as `client_disconnected` and closed it at 18:46:57 UTC. When the app came back to the foreground it still showed "Connected". When the user tapped to talk, the turn failed and the app stayed "Disconnected" until it was reconnected by hand. After the socket dropped, Home recorded no open, no fresh claim and no submission from the app. Cause: when the lifecycle teardown closed the Home client, it never cleared `connectionState`. The foreground short-circuit (`AppleLifecycleCoordinator.process(.active)`) and `verifiedTurnBinding` both trusted that stale `.connected`. A submit that failed on a dead transport went to `.disconnected` and never retried.

**Approach:** (1) The lifecycle teardown marks the store disconnected: `connectionState`, `homeBridgeState`, `sessionMetadata`. (2) `.active` skips activation only when a live transport exists. In Home mode that means a client and a conversation binding are present. Otherwise it activates and reconnects. (3) In Home mode, `verifiedTurnBinding` is nil without a live client and binding, so tap-to-talk cannot start over a dead transport. (4) A Home submit that fails at the transport (`markHomeSubmissionUncertain`) schedules `scheduleHomeConnectRetry`. The retry reopens the held claim and never resends the uncertain prompt, which stays offered for Resend or Continue.

</frozen-after-approval>

## Implementation Notes

- Tests come first, and each must fail on 8c3f163. They are behavioral, through `AppleLifecycleCoordinator`, `ConversationStore` and the Home fakes:
  - (a) backgrounding leaves the store disconnected, and the next `.active` reopens the held claim;
  - (b) `.active` with a cached `.connected` but no live client still connects;
  - (c) `verifiedTurnBinding` is nil in Home mode without a client and binding;
  - (d) a submit that fails `transport_unavailable` reaches connected without user action, does not resend, and keeps the unconfirmed turn.
- Leave unchanged: the IOS-HOME-04 serialized lifecycle, the retry ladder, and IOS-HOME-05 audio deadlines.
- Follow-up, out of scope: automatic diagnostics stopped uploading after 18:41:23 while the app was active, and reports carry no build SHA. Both hid the incident telemetry.
- Files: `AppleLifecycleCoordinator.swift` now skips `.active` only when `store.hasLiveTransport` is true. In `ConversationStore.swift`: `hasLiveTransport` was added; `takeHomeClientForLifecycle` marks a Home store disconnected but keeps a `.failed` state; `verifiedTurnBinding` requires a Home client and binding; `markHomeSubmissionUncertain` schedules `scheduleHomeConnectRetry`. New tests are in `AppleLifecycleTests.swift` and `HomeClientPairingTests.swift`.
- Surprise: in Home mode `SessionMetadata.sessionID` is nil, so `verifiedTurnBinding` was already nil once the teardown dropped the binding. Case (c) is asserted inside tests (a) and (b), and those assertions passed on 8c3f163. The `homeClient` check is defensive.
- Test (b) failed on 8c3f163 because the teardown left `.connected` in place. After the fix, the teardown itself sets the store disconnected, so `hasLiveTransport` is the second line of defense.

## Review Triage Log

- Test (b) does not isolate `hasLiveTransport`: low, accepted. No reachable state has `.connected` with no Home client once the teardown clears the state. The test proves the user-visible outcome and failed before the fix.
- Teardown overwrote `.failed`/`.unavailable` reasons: medium. Patched: a `.failed` state is kept, and only a live or pending state becomes `.disconnected`.
- Retry not cancelled on teardown: false. `lifecycleWillDeactivate` calls `cancelHomeConnectRetry()` before the client is taken, and the retry task re-checks `isCurrentHomeOperation` (the generation is bumped).
- Thin retry coverage (non-retryable, exhaustion): low, rejected. IOS-HOME-04 covers the ladder and its stops. `isRetryableTransportFailure` gates non-transport codes unchanged.
- Spec housekeeping (status, tracking, staging): resolved in the same commit.
- Non-Home mode trusts cached `.connected`: false for this scope. The legacy transport keeps its own reconnect loop and is not closed by the lifecycle teardown.
