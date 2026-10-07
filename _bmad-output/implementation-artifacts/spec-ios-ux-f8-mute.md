---
title: 'IOS-UX-F8 — Mute Hermes's voice without interrupting the reply'
type: 'feature'
created: '2026-10-07'
status: 'backlog'
route: 'dispatch'
review_loop_iteration: 0
parity_tag: 'FB-MUTE'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The user sometimes needs Hermes to stop talking without stopping Hermes. Today the only way to silence a reply is Interrupt, which ends the turn.

**Approach:** A sticky mute that gates only local playback: audio frames are still consumed and dropped, no interrupt is sent, text keeps streaming. Two defaults are proposed for owner confirmation.

</frozen-after-approval>

## Scope

**Parity:** tag `FB-MUTE`. iOS and macOS: `IOS-UX-F8` (hermes-relay-ios). Android: `ANDROID-VOICE-06` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

### Acceptance criteria (shared wording, FB-MUTE)

1. While connected, a mute control is visible next to the other voice controls. It is visually and positionally distinct from Interrupt and never shares its glyph or label.
2. Muting during a reply silences output at once. No interrupt is sent; reply text keeps streaming; the turn finishes normally and its phase and completion are unchanged.
3. While muted, incoming reply audio is still received and consumed, then dropped. Nothing is buffered for later playback, and end-of-reply does not wait for dropped audio to play.
4. Mute is sticky: it applies to every following reply until the user taps unmute.
5. [Proposed default, owner to confirm] Mute is not kept across app restarts; the app always launches unmuted.
6. [Proposed default, owner to confirm] Unmuting mid-reply resumes live audio from the current point; dropped audio is never replayed.
7. The muted state is always visible: the control shows a muted glyph and "Muted" appears in the status line. Screen readers read the control as "Mute Hermes" or "Unmute Hermes" and announce the new state once per change.
8. While muted, reply text is shown as it streams rather than waiting for speech that will not play.
9. Interrupt still works while muted and still ends the turn. Mute does not change capture, hands-free or barge-in rules, system volume, or other apps' audio.
10. Each mute change writes one content-free diagnostics journal line naming the new state and whether a reply was playing.
11. Large: the mute control sits with the small orb as placed by the approved FB-LAYOUT proposal; compact placement is next to the voice control.

### iOS and macOS today

Checked against `origin/main` (dda7181):
- **Mute gates here:** `VoiceSessionCoordinator.swift:1352-1369`, the `.audioChunk` case, calls `output.append(pcm)` at `:1358` (`AppleAudioOutput.append`, `AppleAudioOutput.swift:115`, which schedules on `AVAudioPlayerNode` at `:331`). While muted the chunk is still received and counted (`streamedAudioBytes`, `:1354`) and is dropped instead of appended. The file-audio path (`.audioFileStart`/`.audioFileChunk`/`.audioFileEnd`, `:1397-1420`) must drop the same way.
- End of reply: `.audioEnd` (`:1371-1395`) calls `output.finish()` and ends the response only if `audioDeliveryStarted` (`:1388-1392`), otherwise `handlePlaybackFailure` (`:1592`). Muted dropping must count as delivered so a muted reply never becomes a playback failure.
- Reply reveal: `RecentTranscriptRail.swift:550-564` and `:743-746` reveal text in step with playback (IOS-UX-F5). Criterion 8 needs this to show streamed text when muted.
- **Distinct from Interrupt:** `VoiceSessionCoordinator.swift:1133-1140` (`interruptActiveTurn`) stops output and sends the interrupt; `ConversationStore.swift:2667`. Mute must call neither.
- Journal: `VoiceSessionCoordinator` writes content-free lines such as `voice response started path=voice` (`:888`); mute adds `voice output mute=on|off reply=playing|idle`.
- macOS: `AppleAudioOutput` has no platform branches; the same path applies.

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: same mute control, journal line and placement as iPad.
- Mute is process memory in the voice coordinator, not `@AppStorage` (criterion 5 default).

## Verification

- Focused XCTest with a fake output: no interrupt sent while muted; chunks consumed and not appended; muted reply completes without playback failure; sticky across replies; unmute resumes live; journal line once per change.
- Full iOS Simulator suite and macOS build.
- On device: mute mid-reply on speaker and headphones, VoiceOver labels.
