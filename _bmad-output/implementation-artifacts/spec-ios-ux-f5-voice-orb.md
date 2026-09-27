---
title: 'IOS-UX-F5 — Make the voice orb the talk control'
type: 'feature'
created: '2026-09-27'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/mockups/key-conversation.html'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** On the voice screen the big central orb shows a microphone but does nothing when tapped; the real control is a small button in the bottom bar. Jensen repeatedly taps the orb expecting to record, and expects a recording to end without a second tap. Hands-free interrupts Hermes on any recognised speech over headphones, so it feels too sensitive. Reply text streams in while Hermes is still thinking and is unreadable. The ▲▼ prompt-history arrows are unlabelled and leak prompts across Profiles.

**Approach:** Implement the voice controls UX pass (the DESIGN.md and EXPERIENCE.md spines above, decided with the user on 2026-09-27). The spines are the contract; this spec only sequences the work.

</frozen-after-approval>

## Scope

1. **Voice orb as the only talk control.** Tap to talk, send, or interrupt; the glyph shows the action and the status line reads "State · Action". Cancel under the status line while a tapped recording listens. Remove the bottom-bar microphone button and its label. Not a button when not connected.
2. **Send on a pause.** A tapped recording ends after the existing 1.5 s silence endpoint and sends; tapping sends early.
3. **"Keep listening" pill** under the status line (iOS), replacing the bottom-bar hands-free control. A Settings opt-in "Interrupt Hermes by talking (headphones only)", off by default, gates voice barge-in; with it off, interrupting is tap-only on every route.
4. **Reply text follows the voice.** No assistant text in the reply rail before speech starts; while speaking, reveal in step with the audio (word timing where present, otherwise sentence by sentence). The user's own live words still show while capturing.
5. **Recent prompts.** One clock button left of the composer, only when there is history, opening a menu of up to 8 recent typed prompts (newest first) that fill the composer without sending. Memory only; cleared when the Profile changes.

## Boundaries

- No Hermes protocol, Home, or wire change. No new persisted data; recent prompts and settings stay local (the opt-in is a local preference).
- Hands-free is never armed automatically; existing disarm rules stay.
- The existing echo-safe route rule still applies when the barge-in opt-in is on.
- Content-safe diagnostics only.
- macOS: orb, status line, Cancel, reply rail and Recent prompts; no hands-free pill or barge-in setting.

## Verification

- Focused XCTest for the orb action mapping, send-on-pause for tapped capture, barge-in gating, reply reveal gating, and recent-prompt scoping.
- Full iOS Simulator suite and macOS build.
- On device: Key Flows 1 and 2 in EXPERIENCE.md, plus VoiceOver order and reduced motion.
