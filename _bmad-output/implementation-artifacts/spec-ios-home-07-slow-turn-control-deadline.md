---
title: 'IOS-HOME-07: let slow accepted Home turns finish'
type: 'bugfix'
created: '2026-10-04'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** On Amanda's iPhone, an accepted Home turn was abandoned before its reply arrived. The phone closed its Home socket about 32 s after submission, while Standard finished the reply about 62.7 s after accepting the prompt. The privacy-safe device journal recorded `reconnect_required` and then `unresolved_turn=true`, but no explicit timeout event. Code sets a 30 s `HomeTurnAudioDeadlines.controlTerminal` from acceptance, so a timeout is a strong but unconfirmed cause. When this deadline fires, iOS marks the submission uncertain and reconnects, so the slow reply is never delivered.

**Approach:** Raise the default control-terminal deadline from 30 s to 120 s, matching Home's `DEFAULT_CLIENT_RECONNECT_GRACE_SECONDS` claim lifecycle bound. A turn that Home still keeps alive can then finish and deliver without replay, while a genuinely stuck turn still fails through the existing bounded `controlTerminalMissing` path. Add a deterministic fake-clock regression covering an accepted turn that completes after 63 s and a turn with no terminal that still fails at 120 s.

</frozen-after-approval>

## Implementation Notes

- `HermesRelay/Models/HomeBridgeModels.swift`: changed `HomeTurnAudioDeadlines.default.controlTerminal` from 30 s to 120 s and documented why. No other deadline values changed.
- `HermesRelayTests/VoiceSessionCoordinatorTests.swift`: `makeHomeVoiceReviewFixture` now accepts a `homeClock`. Added two `ManualBackgroundClock` regressions. Before the fix, both failed (5 assertion failures). After the fix, both pass, and the full macOS suite passes with 595 tests and 0 failures.
- Confirmed in Home source that `mark_disconnected` starts the 120 s `client_reconnect_grace` only for an active client claim that is mid-turn (`activity != ready`). Home does not expire the claim while the client stays connected.
- The unsupported server-to-client approval request in Standard's log is a separate capability gap. This change does not address it.

## Review Triage Log

- Blind Hunter, "120 s equals Home grace with no margin; race at expiry": `false`. Home's grace begins when the client disconnects (`mark_disconnected`), not when the turn is accepted. While the phone is connected, Home does not expire the claim, so the client deadline cannot race it.
- Blind Hunter, "tests assert no timeout after a fixed 50 ms sleep": `low`, rejected. Both tests failed under the old 30 s value with this same wait, so the wait is enough for the timer task to run. Switching to a signal-based wait would add machinery for little benefit.
- Blind Hunter, "spec untracked/in-progress, empty notes; code comment states cause as fact": `low`, patched. The spec is now finalized and committed. The code comment states only the observed 63 s duration and Home's grace, not the unconfirmed cause.
- Blind Hunter, "no test for UI state during the longer silent wait": `low`, rejected. The UI state machine is unchanged; only the duration of the existing thinking state grows.
