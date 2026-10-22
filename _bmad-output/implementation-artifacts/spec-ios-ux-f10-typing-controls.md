---
title: 'IOS-UX-F10 — Typing-view controls by the composer: Talk, Mute, Interrupt'
type: 'feature'
created: '2026-10-22'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
parity_tag: 'FB-TYPE'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-ux-f7-typing-view.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-ux-f8-mute.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-ux-f5-voice-orb.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Owner device testing of the typing view (IOS-UX-F7, 0.8.0) found three problems. (1) Mute sits at the top of the transcript, far from the thumb, and is hard to find. (2) The way back to voice is an unlabelled icon left of the composer, so switching to speaking is not obvious. (3) During a reply that icon becomes Interrupt, so Interrupt is the only control: the user cannot mute or switch to voice mid-reply from the typing view.

**Approach:** One labelled control row directly above the composer in the typing view: **Talk**, **Mute/Muted**, **Interrupt**, always in the same order and place, all available during a reply. Follow-up to F7 and F8; their criteria stand except where amended below.

</frozen-after-approval>

## Scope

Compact and large windows alike (large keeps the compact typing view until IOS-UX-F9 is approved, as F7 and F8 do). iOS and macOS. No protocol, Home or coordinator change.

### Acceptance criteria

1. In the typing view a control row sits directly above the composer (thumb zone) with, in order: **Talk** (microphone glyph and the word "Talk"), **Mute** (F8 control: "Mute" / "Muted"), **Interrupt** (raised-hand glyph and the word "Interrupt"). The row is the only place these controls appear in the typing view; the mute control at the top of the transcript and the unlabelled small voice icon are removed. The status line keeps "Muted" (F8 criterion 7).
2. All three controls are visible in every state. Their enabled state:

   | State | Talk | Mute | Interrupt |
   |---|---|---|---|
   | Idle (idle, complete, interrupted, failed) | enabled; returns to voice and starts listening | enabled | disabled |
   | Listening (listening, transcribing, or hands-free armed) | enabled; returns to voice, listening continues | enabled | disabled |
   | Replying (thinking, buffering, speaking) | enabled; returns to voice, the reply keeps playing | enabled | enabled; ends the reply |
   | Muted (any of the above) | as above | enabled, shows "Muted" | as above |

3. Talk never interrupts. When nothing is playing or listening it returns to the voice view, dismisses the keyboard and starts listening through the existing capture path (F7 criterion 4, including permission handling). During a reply it only switches to the voice view; the orb there offers Interrupt as before. **Amends F7 criterion 4** for the reply case.
4. Interrupt in the typing view ends the reply exactly as the orb does (protocol interrupt, F5 rules) but does not start listening and does not leave the typing view.
5. Mute keeps F8 semantics: mute ≠ interrupt, no interrupt is sent, text keeps streaming, unmute resumes live without replaying dropped audio.
6. Accessibility: VoiceOver names "Talk" (value: the voice state; hint describes what Talk will do in that state), "Mute Hermes"/"Unmute Hermes" (toggle), "Interrupt" (dimmed when disabled). Each hit area is at least 44 × 44 pt. Labels stay visible at every Dynamic Type size; at accessibility sizes the row stacks vertically instead of truncating. ⌘⇧L stays on Talk (provisional, F7).
7. The voice view is unchanged: orb, "Keep listening" pill and Mute keep their places; Mute uses the same capsule style in both views.

## Open Questions

PROVISIONAL decisions (owner to confirm):

- Talk during a reply — options: switch view only, reply continues / interrupt and start listening (the old small-control behaviour, the orb's tap). **Provisional: switch only**, so Talk and Interrupt never do the same thing; the user can tap the orb to barge in.
- Interrupt when idle — options: shown disabled / hidden. **Provisional: shown disabled**, so the row never reflows while a reply starts or ends (F7 criterion 5's spirit).

## Code Map

- `HermesRelay/Views/VoiceControl.swift` -- `TypingControlsPolicy` (pure: state → Talk behaviour, Talk hint, Interrupt enabled), `TypingControlCluster`, `TalkButton` (replaces `SmallVoiceControl`), `InterruptButton`, shared `typingControlCapsule` (Dynamic Type capsule, 44 pt hit area) also used by `MuteButton`.
- `HermesRelay/Views/ContentView.swift` -- `composer`: cluster above the text field row in the typing view; `SmallVoiceControl` removed.
- `HermesRelay/Views/AmbientHUD.swift` -- `typingContent`: status line only; `MuteButton` moved to the cluster.

## Tasks & Acceptance

**Execution:**
- [x] `VoiceControl.swift` -- policy, cluster, Talk, Interrupt, shared capsule -- criteria 1-4, 6, 7
- [x] `ContentView.swift`, `AmbientHUD.swift` -- placement -- criterion 1
- [x] `HermesRelayTests.swift`, `VoiceSessionCoordinatorTests.swift` -- tests below
- [x] `story-index.yaml`, `sprint-status.yaml` -- story recorded, status review

## Verification

**Tests (pure, repo pattern; there is no UI test target):**
- `HermesRelayTests`: idle states → Talk listens, Interrupt disabled; listening/transcribing/hands-free → Talk switches only, Interrupt disabled; thinking/buffering/speaking (with and without hands-free) → Interrupt enabled, Talk never listens.
- `VoiceSessionCoordinatorTests`: a muted reply mid-stream keeps Interrupt enabled and Talk non-capturing; unmuting sends no interrupt and the reply completes.

**Simulator screenshots:** `docs/screenshots/ios-ux-f10/` (typing idle, replying, muted).

**Pending device:** thumb reach on iPhone; VoiceOver order Talk → Mute → Interrupt → composer; accessibility Dynamic Type stacking; ⌘⇧L on a hardware keyboard.

## Implementation Notes

Implemented 2026-10-22 on `feat/ios-ux-f10-typing-controls`.

## Verification record

- iOS Simulator (iPhone 18 Pro, Xcode 27.0, CI command): 698 tests, 0 failures (+4 new). macOS: `TEST SUCCEEDED`. No reruns.
- Screenshots `docs/screenshots/ios-ux-f10/` (`typing-idle`, `typing-replying`, `typing-replying-muted`, `typing-idle-muted`): the real `ContentView` hosted in the simulator test host with the coordinator test fakes (scripted relay, fake audio output) and the composer focused; captured with `drawHierarchy`, so the software keyboard (a separate window) is not drawn. The capture harness was throwaway and is not committed.
