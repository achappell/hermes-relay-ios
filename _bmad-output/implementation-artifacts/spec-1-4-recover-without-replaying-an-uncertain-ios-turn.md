---
title: 'Recover without replaying an uncertain iOS turn'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'a6260a44f4bf5e88ab69fb89c84076110c7657ae'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '../hermes-relay-tui/_bmad-output/implementation-artifacts/spec-1-4-recover-without-replaying-an-uncertain-turn.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 1 Story 1.4 ("Recover without replaying an uncertain turn") had no BMad spec artifact for the iOS Client, unlike the analogous TUI slice, even though prior transport-hardening work (IOS-25) had already built most of the required behavior: a bounded background reconnect ladder, an unconfirmed-turn marker that is never auto-resent, and transport-generation isolation of stale frames. The gap was retroactive documentation and an honest audit against the epic's acceptance matrix, not a missing feature.

**Approach:** Audit the existing `ConversationStore` recovery path, `URLSessionHermesSessionClient` transport-generation isolation, and `VoiceSessionCoordinator`'s handling of a lost turn against the Story 1.4 matrix (mirroring the TUI's RECONNECT_SUCCESS / RECONNECT_FAILURE / UNCERTAIN_TURN / STALE_SESSION_FRAME scenarios), confirm existing test coverage proves each scenario, and record the result as a spec rather than rewriting working code.

## Boundaries & Constraints

**Always:** Recovery is visible through `ConnectionState` (`connecting` / `reconnecting(attempt:of:)` / `disconnected` / `failed`); only a successful `hello_ack` restores `connected`. An active turn that loses transport is marked via `unconfirmedTurnText` and is never automatically resubmitted — only an explicit user action (`resendUnconfirmedTurn()`) resends it, and exactly once. A reconnect (automatic ladder or manual `store.connect()`) always negotiates a fresh `sessionID` once the prior socket is torn down; it does not resume the old session. Partial assistant text already rendered before a loss remains visible. Diagnostics stay content-safe.

**Never:** Change the Hermes wire protocol, invent a response, resend a turn the client cannot prove was unsent, discard the draft or transcript during recovery, apply an event from a superseded transport generation, or extend this into Puck/ESP32/web recovery semantics.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Evidence |
|----------|--------------|-----------------------------|----------|
| RECONNECT_SUCCESS | Unexpected transport loss; bounded retry succeeds within policy | `connectionState` cycles `disconnected → reconnecting(n) → connected`; transcript and draft are preserved; no turn is sent | `testReconnectRecoversAndSurfacesReconnectingProgress`, `testReconnectPreservesTranscriptAndDraft` |
| RECONNECT_FAILURE | Bounded attempts exhausted | `connectionState` settles on `.failed(message)`; a later manual `connect()` can still succeed | `testUnexpectedLossRetriesWithBoundedBackoffThenReportsExhaustion`, `testExhaustedReconnectStillAllowsAManualRetry` |
| UNCERTAIN_TURN | Active turn loses transport mid-flight | `unconfirmedTurnText` is set; the turn is not automatically resent; `resendUnconfirmedTurn()` sends it exactly once and clears the marker on success | `testReconnectNeverReplaysAnInFlightTurn`, `testResendingTheUnconfirmedTurnSendsItOnceAndClearsTheMarker`, `testReconnectDoesNotReplayAnUnconfirmedTurn` |
| REPEATED_LOSS | A second unexpected loss is reported while a reconnect is already in flight | The existing backoff ladder continues; no second ladder is started | `testASecondLossWhileReconnectingDoesNotStackAttempts` |
| STALE_SESSION_FRAME | A previous transport's socket still has buffered frames after a new `connect()` | `receiveLoop` and outgoing calls compare against the current `transportGeneration`; a superseded generation cannot mutate `ConversationStore` state | `URLSessionHermesSessionClientTests` transport-generation coverage; structural guard in `receiveLoop(generation:)` |
| INTERRUPT_THEN_LOSS | User interrupts an active turn on an endpoint without server-confirmed interruption | The client falls back to disconnect/reconnect without surfacing it as an unexpected-loss reconnect ladder | `testInterruptingATurnDoesNotStartAReconnectLoop`, `testInterruptingActiveTurnReconnectsWithoutSurfacingTransportFailure` |
| CONFIGURATION_FAILURE | Reconnect fails because of bad configuration/credentials, not transient network loss | Retrying is abandoned immediately rather than exhausting the bounded ladder | `testUnrecoverableConfigurationFailureStopsRetrying` |

</frozen-after-approval>

## Code Map

- `HermesRelayIOS/ViewModels/ConversationStore.swift` — `handleUnexpectedTransportLoss`, `runReconnectLoop`, `resendUnconfirmedTurn`'s callers, `unconfirmedTurnText`, `isReconnecting`: owns recovery state, backoff, and the no-auto-replay guarantee.
- `HermesRelayIOS/Services/URLSessionHermesSessionClient.swift` — `connect`, `markTransportDisconnected`, `transportGeneration`, `receiveLoop(generation:)`: owns fresh-session negotiation and stale-generation frame isolation.
- `HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift` — `resendUnconfirmedTurn()`, `submitVoiceTurn`: owns the visible turn-failure state and the explicit, user-initiated resend path.
- `HermesRelayIOS/Views/ContentView.swift` — wires the manual "Connect" and "Resend unconfirmed turn" actions to `store.connect()` / `voiceCoordinator.resendUnconfirmedTurn()`.
- `HermesRelayIOSTests/ConversationStoreReconnectTests.swift`, `HermesRelayIOSTests/RecoveryTests.swift`, `HermesRelayIOSTests/ConversationStoreTransportTests.swift` — existing deterministic coverage of the matrix above.

## Tasks & Acceptance

**Execution:**
- [x] Audit `ConversationStore` reconnect ladder against RECONNECT_SUCCESS/FAILURE and REPEATED_LOSS — confirmed by existing tests, no code change required.
- [x] Audit unconfirmed-turn handling against UNCERTAIN_TURN — confirmed no automatic resend path exists; only `resendUnconfirmedTurn()` (user-triggered) sends it.
- [x] Audit `URLSessionHermesSessionClient` transport-generation isolation against STALE_SESSION_FRAME — confirmed a superseded generation cannot reach `ConversationStore.apply(_:)`.
- [x] Record this spec retroactively so Story 1.4/`1-i-3-fresh-recovery-without-replay` has a BMad artifact matching the TUI's equivalent.

**Acceptance Criteria:**
- Given an unexpected transport loss, when the bounded reconnect ladder succeeds, then the connection returns to `connected` with the transcript, draft, and any unconfirmed-turn marker unchanged, and no turn is sent automatically.
- Given the bounded ladder is exhausted, when the user takes no further action, then the app remains visibly `.failed` and a later manual `connect()` can still succeed.
- Given a turn loses transport mid-flight, when recovery completes, then the turn is marked unconfirmed and is resent only by explicit user action, exactly once.
- Given a frame arrives from a transport generation superseded by a newer `connect()`, when the client processes it, then it cannot mutate the active session's transcript, phase, or unconfirmed-turn state.

## Implementation Notes

No production code changed. This spec formalizes existing behavior delivered under prior transport-hardening work (IOS-25) as the BMad artifact for Epic 1 Story 1.4 / `1-i-3-fresh-recovery-without-replay`, so sprint-status can reflect reality without re-implementing already-working recovery.

## Deferred

- A physical-device validation pass for this story has not been run. The existing `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md` explicitly reserves Stories 1.3/1.4 for a future extension of that same plan rather than a second device-validation task; deterministic tests remain authoritative for the matrix above until that pass runs.

## Verification

**Commands:**
- `xcodebuild test -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HermesRelayIOSTests/ConversationStoreReconnectTests -only-testing:HermesRelayIOSTests/RecoveryTests -only-testing:HermesRelayIOSTests/ConversationStoreTransportTests` — run 2026-09-10: 29 tests, 0 failures.
