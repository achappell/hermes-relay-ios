---
title: 'IOS-HOME-08: Settle Home audio-tail interruption without losing terminal truth'
type: 'bugfix'
created: '2026-10-07'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
baseline_commit: '422a54731c3cae2142d350781360dc783e1f3904'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The shared Apple Home interrupt path erases an already-observed control result after acknowledgement and waits for another terminal. Home now accepts post-text audio-tail stops and recently retired turn interrupts without emitting another control terminal, so local stop can remain unresolved and prevent the next prompt.

**Approach:** Preserve matching control-terminal evidence and distinguish still-running control interruption from completed-control audio-tail stop and native-buffer-only cancellation. Keep cleanup and waiter ownership bound to the captured turn and response generation across acknowledgement, audio-end, and native-drain races. An acknowledgement alone must not finish a genuinely active control turn. Keep current text, no-replay rules, and newer-turn isolation; do not change audio decoding or unrelated UI.

Regression evidence must cover tail acknowledgement without a second terminal, active acknowledgement still waiting for a matching terminal, native drain ordering, and old-turn isolation. Run failing-before tests, then focused and shared-platform checks, a real local runtime smoke at the Home seam, independent review, and exact-head PR CI. Do not deploy, merge, install on user devices, or use Pixel. Physical-device behavior remains explicitly unverified.

</frozen-after-approval>

## Implementation Notes

- One-shot route: no unresolved user-visible intent choices or irreversible runtime changes; footprint is the existing Home store/coordinator, focused tests, and local workflow evidence. Home PR83/85 preserve the public audio-end shape; decoder changes are excluded.
- `ConversationStore.swift`: preserve `homeTurnResult` in `interruptActiveTurn`; scope completion waiters/cleanup to the accepted `HomeTurnBinding`.
- `VoiceSessionCoordinator.swift`: stop native output without letting old drain completion mutate a newer response; preserve truthful control completion.
- Existing store matching-terminal tests and gated coordinator output fixtures supply deterministic ordering seams. Release Please owns versioned changelog sections; the conventional fix commit supplies release notes.
- Control results and completion waiters now carry the captured Home turn identity. Cleanup takes `completeHomeTurnAfterAudio(for:)`; all callers migrate without an unscoped alias. Acknowledged tail stop releases the audio join while preserving the genuine control result; native-only stop skips the server interrupt.
- Home response generation retires before `output.stop()` releases native drain. The interrupt continuation owns final captured-turn cleanup, including rejected/unavailable outcomes after real terminal delivery, and refreshes an already-shown Now Playing card.
- Added seven regression cases across the existing store/coordinator tests plus `scripts/home-tail-interrupt-smoke.py` and `.swift`: real production store/URLSession networking against an isolated loopback TLS contract peer, with explicit signal gates and no sleeps/replays. This is not deployed-Home or native-hardware evidence.
- Independent review used the configured Blind Hunter layer; no configured review layer was skipped. Focused re-review found no actionable remainder after the three corrections below.

## Review Triage Log

- High, patched: smoke accessed private `homeTurnBinding`; changed to the exposed verified turn binding. Otherwise the runtime smoke could not compile.
- High, patched: early generation retirement removed the normal cleanup owner when Home rejected/unavailable a tail stop. The interrupt continuation now joins the captured response and performs identity-guarded cleanup only after genuine terminals; added rejected/unavailable regression cases.
- Medium, patched: retiring the event-handler generation bypassed the previous Now Playing update. Both failed and successful stopped states explicitly refresh the existing card; the tail-stop test asserts stopped publication.
- Verification correction: the initial native-only fixture emitted audio end before control completion, so its native drain blocked observation of control completion and an interrupt request was legitimate. The fixture now observes control completion before gating audio-end drain; the no-server-interrupt assertion remains.
