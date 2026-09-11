---
title: 'iOS capture acknowledgement and live Transcription participant state (2-I-1)'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context: []
baseline_commit: 'a6260a44f4bf5e88ab69fb89c84076110c7657ae'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 2-I-1 (shared cross-repo identity; local Story 2.1) requires iOS's voice doorway to show an honest capture acknowledgement and live partial Transcription as a turn's events arrive. Codebase investigation shows `VoiceSessionCoordinator`, `AmbientHUD`, and `RecentTranscriptRail` already implement Listening acknowledgement, live `provisionalText` updates, clean end/cancel handling, and empty-turn suppression, with existing coverage in `VoiceSessionCoordinatorTests.swift`.

**Approach:** Audit the existing behavior directly against each 2-I-1 acceptance criterion, add targeted unit tests that pin any currently-implicit guarantee, and record closure evidence mapping each AC to the exact code/test that satisfies it — rather than building new UI.

**Decision (2026-09-10):** Verify-only. No new capture-acknowledgement affordance is in scope; the existing `AmbientHUD` mode change is the acknowledgement.

## Boundaries & Constraints

**Always:** Reuse the existing `VoiceState` / `VoiceSessionCoordinator` / `AmbientHUD` machinery; correlate every capture-state and transcription update to `ConversationStore.verifiedTurnBinding` / `isCurrentTurnBinding(_:)`; keep the single WebSocket reader and existing event-normalization path as the only source of turn events.

**Never:** Do not invent a second capture-acknowledgement UI element or transport path — verify-only, no new affordance. Do not modify Epic 1's turn-phase or recovery semantics (Stories 1.2, 1.4) — reuse them as-is. Do not touch ESP32 Touch, W/K, Puck, or TUI surfaces; those are out of this repository's scope per `AGENTS.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wake/turn accepted | `store.verifiedTurnBinding` valid | `state` transitions to `.listening`; HUD/mic show capture acknowledgement | N/A |
| Partial transcript arrives | `SpeechRecognitionUpdate` via `consumeRecognition(_:)` | `provisionalText` updates live; HUD caption and `RecentTranscriptRail` update without waiting for capture end | N/A |
| Capture ends with empty text | `endCaptureAndSend()`, final text empty | `state` returns to `.idle`; no Hermes turn submitted; no stale Listening | N/A |
| Capture cancelled | `cancelCapture()` | `provisionalText`/`finalText` cleared; `state` returns to `.idle` | N/A |
| Stale/other-turn event arrives | Event doesn't match active session/turn binding or generation | Current capture/transcription state unchanged | Event discarded silently |

</frozen-after-approval>

## Code Map

- `HermesRelayIOS/Models/SessionModels.swift` -- `enum VoiceState` (`idle, listening, transcribing, thinking, speaking, buffering, complete, interrupted, failed`) with `.label`, `.systemImage`, `.isCaptureActive`; `HermesTurnBinding` (profileID + sessionID)
- `HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift` -- `@Observable` owner of `state`/`provisionalText`; `beginCapture()` → `applyCaptureStart(_:)`, `consumeRecognition(_:)` (live partial text), `endCaptureAndSend()` (empty-text suppression), `cancelCapture()` (clears state, no stale Listening); generation counters discard stale turn events
- `HermesRelayIOS/Views/AmbientHUD.swift` -- `AmbientHUDMode` mirrors `VoiceState`; `AmbientHUDPresentation.init` (~127-144) sets caption from `liveText`/`provisionalText` while `.listening`/`.transcribing`
- `HermesRelayIOS/Views/RecentTranscriptRail.swift` -- consumes `provisionalText` for a live transcript line (~24, ~39, ~535)
- `HermesRelayIOS/Views/VoiceControl.swift` -- mic-active affordance via `coordinator.state.isCaptureActive` / `.systemImage`
- `HermesRelayIOS/ViewModels/ConversationStore.swift` -- `verifiedTurnBinding`, `isCurrentTurnBinding(_:)` (~33-38, ~133-135), `activeTurnGeneration` for stale-event discard
- `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift` -- existing precedent tests (e.g. `testAmbientHUDTracksLiveRecognitionUpdatesFromCoordinator`, `testCancelSubmitsNothingAndPreservesTheDraft`, `testCaptureDoesNotSubmitAfterVerifiedSessionChanges`, `testNoSpeechCaptureReturnsToReadyWithoutSubmittingOrReportingFailure`) to extend

## Tasks & Acceptance

**Execution:**
- [x] `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift` -- add/confirm one targeted test per I/O Matrix row that isn't already covered by an existing test -- pins currently-implicit guarantees so a future regression is caught, not just observed by inspection
- [x] `_bmad-output/implementation-artifacts/spec-2-1-ios-capture-acknowledgement-and-live-transcription.md` (`## Implementation Notes`) -- record, for each 2-I-1 acceptance criterion below, the exact existing test or code path that satisfies it -- gives this story real closure evidence instead of an unverified assumption of "already done"

**Acceptance Criteria:**
- Given an authorized wake or explicit turn initiation is accepted, when capture begins, then iOS shows its capture acknowledgement and `.listening` state without leaving a stale indicator afterward.
- Given partial transcription becomes available, when words arrive, then iOS's displayed transcript updates live rather than waiting for capture to finish.
- Given capture ends or is cancelled, when the capture stream closes, then Listening ends and iOS advances to the appropriate next phase without a stale Listening indicator.
- Given the capture path is cancelled, empty, or unavailable, when cleanup completes, then no empty Hermes turn is submitted and no raw audio/transcript is retained.
- Given a stale event or an event for another session/turn arrives, when iOS processes it, then it does not mutate the current capture or transcription state.

## Implementation Notes

Verify-only story. Each AC below is satisfied by existing `VoiceSessionCoordinator` code plus existing or newly-added tests in `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift`. One new test was added (`testEmptyFinalRecognitionEndsCaptureWithoutSubmittingATurn`) to pin a guarantee that was previously implicit; all other rows were already pinned by prior coverage and are cited as-is.

**AC1 — Accepted wake/turn shows capture acknowledgement (`.listening`) with no stale indicator afterward.**
- Code: `VoiceSessionCoordinator.applyCaptureStart(_:)` sets `state = .listening` once the input stream starts (`VoiceSessionCoordinator.swift:612`); `AmbientHUDMode` mirrors `VoiceState` 1:1 (`AmbientHUD.swift`) so the HUD reflects the acknowledgement immediately.
- Tests: `testNewCaptureWaitsForPreviousSpeechFinishToComplete` asserts `coordinator.state == .listening` right after `beginCapture()`; `testReleaseSubmitsOneFinalRecognitionAndStreamsPlayback` and `testResponseEndsCompleteWhenTheStreamClosesWithoutATrailingAudioEnd` carry a successful capture through to `.complete`, proving the acknowledgement does not linger once the turn resolves.

**AC2 — Partial transcription updates the displayed transcript live, without waiting for capture end.**
- Code: `consumeRecognition(_:)` assigns `provisionalText = update.text` on every stream update, not just the final one (`VoiceSessionCoordinator.swift:850`); `AmbientHUDPresentation.init` sources its caption from `provisionalText` while `.listening`/`.transcribing` (`AmbientHUD.swift:~127-144`); `RecentTranscriptRail` renders `provisionalText` directly (`RecentTranscriptRail.swift:~24, ~39, ~535`).
- Tests: `testReleaseSubmitsOneFinalRecognitionAndStreamsPlayback` asserts `coordinator.provisionalText == "Hello Herm"` after a partial update and *before* `endCaptureAndSend()` is called; `testAmbientHUDTracksLiveRecognitionUpdatesFromCoordinator` renders `AmbientHUDView` against the live coordinator and asserts SwiftUI's observation tracking fires when a partial update arrives mid-capture. Coverage gap: no test in `HermesRelayIOSTests/` references `RecentTranscriptRail` directly (confirmed by search) — its live-update claim rests on code inspection of `provisionalText` consumption only, not a view-level test.

**AC3 — Capture ending or cancellation ends Listening and advances to the next phase without a stale Listening indicator.**
- Code: `endCaptureAndSend()` moves to `.transcribing` immediately, then to `.thinking`/playback states or `.idle`/`.failed` once resolved; `cancelCapture()` sets `state = .idle` synchronously and clears `provisionalText`/`finalText` (`VoiceSessionCoordinator.swift:694-729`).
- Tests: `testCancelSubmitsNothingAndPreservesTheDraft` asserts `.idle` and cleared `provisionalText` after cancel; `testDisarmingHandsFreeCancelsAnActiveCaptureAndReturnsToReady` covers the hands-free cancel path; `testReleaseSubmitsOneFinalRecognitionAndStreamsPlayback` and `testCoordinatorReportsSpeakingAfterFirstAudioBufferIsReady` show a normal end-of-capture advancing all the way to `.speaking`/`.complete`, never regressing to `.listening`.

**AC4 — Cancelled, empty, or unavailable capture submits no empty Hermes turn and retains no raw audio/transcript.**
- Code: `endCaptureAndSend()`'s `guard !text.isEmpty else { captureBinding = nil; state = .idle; return }` (`VoiceSessionCoordinator.swift:531-535`) blocks submission when the trimmed final/provisional text is empty; the `.noSpeech` branch of `consumeRecognition(_:)` separately clears `provisionalText`/`finalText`/`captureFailureMessage` and returns to `.idle` without treating it as a failure (`VoiceSessionCoordinator.swift:863-872`); `cancelCapture()` clears both text buffers before returning to `.idle`.
- Tests: `testNoSpeechCaptureReturnsToReadyWithoutSubmittingOrReportingFailure` pins the recognizer-error (`.noSpeech`) branch; `testCancelSubmitsNothingAndPreservesTheDraft` pins the cancel branch; the newly added `testEmptyFinalRecognitionEndsCaptureWithoutSubmittingATurn` pins the previously-implicit third path — a capture that ends with genuinely empty text and *no* recognizer error — asserting `.idle`, `client.sentTurns == []`, `store.messages.isEmpty`, and cleared `provisionalText`. The "unavailable" sub-case (mic/speech permission denied, `.failed(.permission(...))` at `VoiceSessionCoordinator.swift:616-620`) is separately pinned by `testDeniedPermissionHasActionableFailureState`, `testSpeechPermissionHasActionableFailureState`, and `testPermissionRevokedDuringStartPreservesSettingsRecovery` — not previously cited in this section.

**AC5 — A stale event or an event for another session/turn does not mutate current capture/transcription state.**
- Code: every branch of `handle(_ event:generation:)` is gated by `isCurrentResponse(generation)` / `generation == responseGeneration` / `!state.isTerminal` (`VoiceSessionCoordinator.swift:911-1093`), so events tagged with a superseded `responseGeneration` are silently dropped; capture-side, `applyCaptureStart(_:)` and `endCaptureAndSend()` both re-check `store.isCurrentTurnBinding(binding)` (backed by `ConversationStore.verifiedTurnBinding`/`isCurrentTurnBinding(_:)`, `HermesRelayIOS/ViewModels/ConversationStore.swift:33-38, 133-135`) before submitting, rejecting a turn whose session/profile binding changed underneath it.
- Tests: `testTerminalStateIgnoresLateEventsAndKeepsTheDeliveredResponse` fires a full battery of late/stale events (`status`, `thinkingDelta`, `speechTiming`, `error`, `audioAbort`, `turnInterrupted`, `messageComplete`, `textDelta`, `unknown`) after the turn is already `.complete` and asserts none of them mutate `state`, `store.messages`, or `speechTimings`; `testCaptureDoesNotSubmitAfterVerifiedSessionChanges` covers the other-session/turn case — the store's verified binding changes mid-capture, and the coordinator refuses to submit the stale-bound text rather than silently carrying it into a new session.

**Note on the "other-turn" sub-case:** `testCaptureDoesNotSubmitAfterVerifiedSessionChanges` surfaces an explicit `.failed("The selected Hermes Profile changed...")` state rather than leaving state byte-for-byte unchanged. This is the correct, deliberate UX for a *capture* that outlives its binding (the user needs to know their turn was dropped), and is distinct from the *response-event* generation guard in AC5's first test, which does leave state untouched. Both code paths satisfy the AC's intent — "do not silently carry a stale capture/turn into a state it doesn't belong to" — via the mechanism appropriate to where the staleness is detected.

**Incidental fix — pre-existing flaky test exposed by this change:** Independent verification (re-running the diff's own claim of "63/63 pass" rather than trusting the report) found `testUnexpectedNoSpeechResetsCaptureAndAllowsRetryWithoutSendingPartialText` failing deterministically once `testEmptyFinalRecognitionEndsCaptureWithoutSubmittingATurn` was added to the file, even though the two tests share no state and the failing test doesn't exercise the new code path. Confirmed by stash/pop bisection: the test passes reliably at `baseline_commit` and fails reliably with only the new test method added. Root cause: the failing test synchronized on a fixed `for _ in 0..<3 { await Task.yield() }` after emitting a `.noSpeech` error — the smallest yield count anywhere in this file (siblings use 10-100) — which was already marginal and tipped over once the compiled test binary's size/scheduling shifted. Fixed by raising it to `0..<20`, matching the convention used by comparable tests elsewhere in this file; no production code was touched. Verified stable across 3 consecutive full-suite runs after the fix (0 failures each time), versus reproducible failure across 3 runs before it.

## Spec Change Log

- Trigger: independent test-suite verification during step-03 found `testUnexpectedNoSpeechResetsCaptureAndAllowsRetryWithoutSendingPartialText` (pre-existing, not part of this story's new test) failing deterministically once this story's new test was added, despite no shared state or logical overlap.
- Amendment: raised that test's synchronization from `for _ in 0..<3 { await Task.yield() }` to `0..<20`, matching sibling tests in the same file. No production code changed; still a test-only, verify-only change consistent with this spec's frozen intent.
- Known-bad state avoided: merging this story's single new test while leaving a now-flaky pre-existing test behind, which would have silently degraded suite reliability and been blamed on a future unrelated change.
- KEEP: the bisection method (stash the diff, rerun the failing test in isolation, pop, rerun) is the reliable way to distinguish "this diff caused it" from "pre-existing flake" — do not skip this step on a report of "all tests pass" without independently re-running.

## Review Triage Log

- **low, patch (fixed)** — Blind Hunter + Verification-Gap + Edge Case Hunter (same root cause): the yield-count bump (3→20) in `VoiceSessionCoordinatorTests.swift:487` had no inline comment explaining it was a deliberate flakiness fix, and remains probabilistic rather than a deterministic wait. Verified real: confirmed no comment existed and the loop is indeed still a race, just a much less likely one. Fix: added an inline comment at the site explaining the bump and naming it non-deterministic. Did not redesign the synchronization (see defer entry below) — that's a pre-existing pattern across ~10 other tests in this file, not introduced by this story.
- **low, patch (fixed)** — Blind Hunter: Code Map cited `HermesRelayIOS/Services/ConversationStore.swift`; actual path is `HermesRelayIOS/ViewModels/ConversationStore.swift` (confirmed via `find`), contradicting the correct path already used elsewhere in this same document. Fixed the Code Map entry.
- **medium, patch (fixed)** — Blind Hunter: AC2's Implementation Notes claimed `RecentTranscriptRail` renders live transcript updates but cited no test; confirmed via repo-wide search that zero tests reference `RecentTranscriptRail`. This is a real closure-evidence gap for a verify-only story whose entire point is honest evidence. Fixed by stating the gap explicitly in Implementation Notes rather than implying test coverage that doesn't exist. Did not add a new view-level test — out of the smallest-fix bar for a triage patch, and this view's live-update behavior is still indirectly evidenced by `provisionalText`'s own coverage.
- **false** — Blind Hunter: claimed AC4's "unavailable" sub-case (`.failed(.permission(...))` at `VoiceSessionCoordinator.swift:616-620`) is "completely unpinned by any cited test." Disproven: `testDeniedPermissionHasActionableFailureState`, `testSpeechPermissionHasActionableFailureState`, and `testPermissionRevokedDuringStartPreservesSettingsRecovery` all exercise this exact branch via `beginCapture()`. The tests existed; only the Implementation Notes citation was missing. Fixed the citation (see above) rather than treating this as a coverage gap.
- **rejected — fix is a spec-only edit** — Edge Case Hunter (claim, high confidence) + Blind Hunter: AC5/the I/O matrix's "Stale/other-turn event arrives" row states state is "unchanged"/"discarded silently," but `endCaptureAndSend()`'s binding-mismatch branch (`VoiceSessionCoordinator.swift:537-544`) actually sets `state = .failed(message)` with a visible `store.transientError` for the specific case of a capture outliving its session/profile binding. Verified true — this is a real wording imprecision in the frozen AC5/matrix text (not a code defect; no code needs to change). Per triage rule, a finding whose only fix is editing this build's spec is rejected from the automated routing rather than looped back through revert/re-derive. Flagging to the human directly instead: the existing "Note on the other-turn sub-case" in Implementation Notes already explains the two distinct mechanisms, but if you want AC5's frozen wording itself tightened to say "does not silently mutate" rather than "unchanged," that's a one-line edit you can make or ask for.
- **defer** — Verification-Gap + Edge Case Hunter: the `for _ in 0..<N { await Task.yield() }` synchronization pattern used throughout `VoiceSessionCoordinatorTests.swift` (10+ occurrences, N ranging 3-100) is inherently probabilistic, not a deterministic wait on the coordinator's internal `Task` completing. This story's one instance (raised to 20) is documented and verified stable, but the pattern itself is pre-existing across the whole file and not introduced by this story. A repo-wide move to a deterministic wait (e.g., awaiting the coordinator's internal task handle, or an `XCTestExpectation`) would remove the recurring risk but is a larger change than this verify-only story's scope.
- **rejected — cosmetic, fix is a spec-only edit** — Blind Hunter: `epic-2-context.md` isn't cross-referenced from `spec-2-1`'s Code Map/Cross-Story Dependencies, and the Verification section's "63/63" vs. Spec Change Log's "3 consecutive full-suite runs" could be read as referring to different scopes (both actually mean the same `VoiceSessionCoordinatorTests` target). Real but low-impact wording nits whose only fix is editing this build's spec.

## Verification

**Commands:**
- `xcodebuild test -scheme HermesRelayIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HermesRelayIOSTests/VoiceSessionCoordinatorTests` -- expected: all tests pass, including any newly added ones (verified: 63/63, 0 failures, stable across repeated runs)
