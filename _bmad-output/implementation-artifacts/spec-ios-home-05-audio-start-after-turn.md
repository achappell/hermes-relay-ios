---
title: 'IOS-HOME-05: Home audio-start deadline starts when the text turn completes'
type: 'bugfix'
created: '2026-10-04'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** On the pilot iPhone (build from main 66477da, Home 082e593), a reply that took about 23 s to generate showed "Audio playback failed. The response text is still available." Home relayed the full audio afterward (turn accepted 17:41:08Z, turn completed 17:41:31.86Z, audio started 17:41:31.93Z, audio completed 17:41:43.55Z with 729600 bytes, no failure code). `ConversationStore.sendDraft` starts `scheduleHomeAudioStartDeadline` (5 s) when the turn is accepted. Standard synthesizes reply audio only once the text completes, so any reply slower than 5 s is marked `audioStartMissing`, aborted as `"unavailable"`, and reported as a playback failure.

**Approach:** Start the audio-start deadline when the Home text turn completes successfully (`finishHomeControlTurn(success: true)`), and only if audio has not already started or ended. Keep the 30 s `controlTerminal` deadline from acceptance as the guard for a turn that never completes. Do not change deadline values. Regression tests: (1) slow text, then audio → no failure, audio delivered; (2) no `audioStart` within the deadline after turn completion → still fails as `"unavailable"`.

</frozen-after-approval>

## Implementation Notes

Implemented in `ConversationStore.finishHomeControlTurn(success:)`: arm audio-start deadline after successful text completion only when audio has not started or terminated. Kept the 30 s acceptance-time control deadline. `VoiceSessionCoordinator` now defers Home's no-audio `turnComplete` failure to the Home audio terminal/deadline.

Added delayed-audio and missing-audio regression tests in `HermesRelayTests/VoiceSessionCoordinatorTests.swift`. The delayed-text test failed before the fix (playback failure; no audio append) and passed afterward.

Blind review found no issues.
