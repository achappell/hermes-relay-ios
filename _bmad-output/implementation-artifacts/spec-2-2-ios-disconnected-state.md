---
title: 'Honest iOS disconnected/unavailable state (2-I-2)'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 2-I-2 requires the iOS voice doorway to show an honest disconnected or unavailable state after transport loss or failed recovery, while retaining only safe cached context and never replaying an uncertain turn. The existing client already has explicit connection states, bounded recovery, cached transcript/draft preservation, and an unconfirmed-turn marker; this slice must prove that those behaviors are visible and remain isolated from stale session events.

**Approach:** Audit `ConversationStore`, `ConnectionState`, and `AmbientHUD` against the story's recovery and presentation contract. Add targeted deterministic regression coverage for any guarantee that is only implicit, and make the smallest production change only if the audit finds a user-visible gap.

**Always:** Keep disconnected, reconnecting, and unavailable states visible and actionable; retain safe cached transcript/draft context with its stale or unconfirmed indication; transition to Connected only after a fresh verified session succeeds; never automatically resend a turn whose delivery is uncertain; discard stale session/turn events without mutating current UI state.

**Never:** Do not invent a transport operation or alter Hermes protocol semantics; do not clear safe cached conversation merely because transport is unavailable; do not silently resume a prior turn; do not change device, TUI, or W/K behavior; do not claim a live endpoint or physical-device validation where deterministic tests are the authority.

**Acceptance:** A transport loss remains visibly disconnected/reconnecting/unavailable with a manual Connect or Retry path; transcript and draft remain safe and visibly contextualized; recovery creates a fresh verified session without replay; explicit resend is the only resend path; late events from the prior session cannot change the recovered transcript, phase, or audio state.

</frozen-after-approval>

## Implementation Notes

This slice began as a verification pass, then the review exposed two user-visible gaps. The smallest production fix now labels retained local context as non-live and cancels ordinary capture when the connection leaves Connected; the transport test suite also pins replacement-session isolation.

- `HermesRelayIOS/Models/SessionModels.swift` keeps `.disconnected`, `.reconnecting`, and `.failed` distinct and gives them honest labels (`Not connected`, `Reconnecting…`, `Unavailable`).
- `HermesRelayIOS/Views/AmbientHUD.swift` renders `connectionState.label` in the persistent session header, exposes `Connect`/`Retry` whenever the state is not connected, labels retained transcript context `Cached conversation` and `not live`, and renders the unconfirmed-turn warning with an explicit `Resend` action.
- `HermesRelayIOS/Views/ContentView.swift` labels an unsent draft as saved locally while unavailable and cancels ordinary capture before disarming hands-free whenever the connection leaves Connected, so the main voice state cannot linger in Listening during an outage.
- `HermesRelayIOS/ViewModels/ConversationStore.swift` clears verified session metadata on loss, preserves messages/draft/unconfirmed text, runs one bounded reconnect ladder, and marks Connected only after `HermesSessionClient.connect()` returns fresh metadata. Its verified turn binding prevents new turns while unavailable.
- `HermesRelayIOSTests/URLSessionHermesSessionClientTests.swift` adds `testReplacementSocketStartsAFreshSessionAndIgnoresLateOldFrames`, proving that a replacement socket receives a different session ID and that an old socket's late text cannot enter the new turn.
- Existing deterministic coverage maps the remaining contract: `ConversationStoreTransportTests` covers visible failure, stale-connected-state clearing, and hello-ack-gated recovery; `ConversationStoreReconnectTests` covers reconnecting progress, cached transcript/draft preservation, bounded failure, manual retry, no automatic replay, and explicit resend; `RecoveryTests` covers no replay across manual reconnect; `VoiceSessionCoordinatorTests` covers capture cancellation and stale binding rejection.

## Review Triage Log

- **medium, patch (fixed)** — Blind Hunter found that completed transcript history and drafts had no clear cached/non-live indication. Added `Cached conversation`/`Saved locally; not live while Hermes is unavailable.` to `AmbientHUD` and `Draft saved locally. Connect before sending.` to the composer; simulator snapshot confirmed both labels while unavailable.
- **medium, patch (fixed)** — Blind Hunter found that a transport loss only disarmed hands-free, allowing ordinary microphone capture to remain active and present Listening during an outage. `ContentView` now cancels ordinary capture before disarming hands-free on every non-connected state; existing coordinator cancellation tests and the full suite pass.
- **medium, patch (fixed)** — Blind Hunter found that the cited late-frame coverage only proved same-socket turn-ID filtering. Added `testReplacementSocketStartsAFreshSessionAndIgnoresLateOldFrames`, which queues an old-socket frame after replacement and asserts only the fresh response reaches the new stream.
- **medium, patch (fixed)** — Blind Hunter found that the recovery fixture did not prove a fresh session identity. The same replacement-socket test asserts distinct `SessionMetadata.sessionID` values for the original and replacement handshakes.
- **low, patch (fixed)** — Blind Hunter found that the artifact remained `in-progress` and lacked reproducible closure evidence. Marked it `done` and added the exact verification commands, acceptance mapping, and simulator smoke result below.

## Verification

**Commands:**

- `xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/hermes-relay-ios-2i2-focused -only-testing:HermesRelayIOSTests/URLSessionHermesSessionClientTests -only-testing:HermesRelayIOSTests/ConversationStoreReconnectTests -only-testing:HermesRelayIOSTests/ConversationStoreTransportTests` — 51 tests passed, 0 failures.
- `xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -derivedDataPath /tmp/hermes-relay-ios-2i2-ios-final` — 296 tests passed, 0 failures.
- `xcodebuild build -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' -derivedDataPath /tmp/hermes-relay-ios-2i2-macos-final` — `BUILD SUCCEEDED`.
- `git diff --check` — no whitespace errors.

**Acceptance evidence:**

- Disconnected/recovery presentation: `AmbientHUD` exposes `Unavailable`/`Retry`, retains cached transcript content, and the simulator snapshot showed the state remaining unavailable after tapping Retry against the unavailable local relay.
- Safe local context: the same snapshot showed `Cached conversation. Saved locally; not live while Hermes is unavailable.` and, after entering a draft, `Draft saved locally. Connect before sending.` No draft or transcript was sent.
- Fresh verified recovery without replay: `ConversationStoreReconnectTests`, `RecoveryTests`, and the replacement-socket test cover fresh connection metadata, bounded recovery, no automatic resend, and explicit resend only.
- Stale-event isolation: `testReplacementSocketStartsAFreshSessionAndIgnoresLateOldFrames` proves old-socket text is ignored after a new session is active; `testSendTurnIgnoresLateFramesForAnotherTurn` covers same-socket turn filtering.

The simulator smoke used the unavailable local relay and does not claim live Hermes endpoint or physical-device validation.
