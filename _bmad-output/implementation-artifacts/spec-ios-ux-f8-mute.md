---
title: 'IOS-UX-F8 — Mute Hermes's voice without interrupting the reply'
type: 'feature'
created: '2026-10-07'
status: 'draft'
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

**Approach:** A sticky mute that gates only local playback: audio frames are still consumed and dropped, no interrupt is sent, text keeps streaming. Launches unmuted; unmuting resumes live.

</frozen-after-approval>

## Scope

**Parity:** tag `FB-MUTE`. iOS and macOS: `IOS-UX-F8` (hermes-relay-ios). Android: `ANDROID-VOICE-06` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

**One layout-class resolver.** The layout class is computed in exactly one place per app and read everywhere else; views never branch on platform or device. On macOS the resolver always returns large. (SDK check: `EnvironmentValues.horizontalSizeClass` is available on macOS 10.15+ per the macOS `SwiftUICore` swiftinterface in Xcode 27.2 beta 2, lines 22064-22066, but nothing there defines its value on macOS, so the resolver does not read it there.)

### Acceptance criteria (shared wording, FB-MUTE)

1. While connected, a mute control is visible next to the other voice controls. It is visually and positionally distinct from Interrupt and never shares its glyph or label.
2. Muting during a reply silences output at once. No interrupt is sent; reply text keeps streaming; the turn finishes normally and its phase and completion are unchanged.
3. While muted, incoming reply audio is still received and consumed, then dropped. Nothing is buffered for later playback, and end-of-reply does not wait for dropped audio to play.
4. Mute is sticky: it applies to every following reply until the user taps unmute.
5. Mute is not kept across app restarts; the app always launches unmuted.
6. Unmuting mid-reply resumes live audio from the current point; dropped audio is never replayed.
7. The muted state is always visible: the control shows a muted glyph and "Muted" appears in the status line. Screen readers read the control as "Mute Hermes" or "Unmute Hermes" and announce the new state once per change.
8. While muted, reply text is shown as it streams rather than waiting for speech that will not play.
9. Interrupt still works while muted and still ends the turn. Mute does not change capture, hands-free or barge-in rules, system volume, or other apps' audio.
10. Each mute change writes one content-free diagnostics journal line naming the new state and whether a reply was playing.
11. Large: the mute control sits with the small orb as placed by the approved FB-LAYOUT proposal; compact placement is next to the voice control.

## Open Questions

PROVISIONAL decisions: the owner has not confirmed these. Work proceeds on them under the director's authorization; the owner corrects afterwards.

- Dependency on `IOS-UX-F9` — options: ignore F9 for compact work (compact criteria build now; iPad and Mac use compact placement until F9 is approved) / wait for F9 approval (nothing ships). **Provisional: ignore F9.** `story-index.yaml` still lists `ios:IOS-UX-F9` as a dependency while this spec says compact criteria are buildable now; the index is left unedited and the mismatch is recorded here.
- Dependency on `IOS-UX-F5` (still `in-progress` in the tracker) — options: F5's reply rail is on `main` (`084c568`), so build on it / wait for F5 device acceptance. **Provisional: build on it.** Criterion 8 needs only the rail code, not F5's closure. F5's pending device checks stay F5's.
- Status line wording while muted — options: keep the state word and add a "Muted" segment ("Speaking · Muted · Tap to interrupt") / replace the state word. **Provisional: add the segment**, shown whenever muted, including idle ("Ready · Muted · Tap to talk").
- Muted reply state — options: first dropped non-empty chunk moves the state to `.speaking` as unmuted would (Interrupt, hands-free and Now Playing rules unchanged) / add a new `VoiceState`. **Provisional: `.speaking`**, no new state.

## Code Map

Verified against `origin/main` e58974f (the line numbers in the earlier draft had drifted).

- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift` -- `handle(_:generation:)` (`:1339`): `.audioStart` `:1345` (calls `output.start`), `.audioChunk` `:1371` (counts `streamedAudioBytes`, then `output.append`, sets `audioDeliveryStarted`, `.speaking`), `.audioEnd` `:1390` (`output.finish()`, ends the reply when `turnDidComplete && audioDeliveryStarted`), file path `:1416-1457`, `.turnComplete` `:1458`. `playRemainingAudioAndEndResponse` `:1588` calls `output.finish()` when a stream is open. `interruptActiveTurn` `:1133` is the Interrupt path; mute must not call it. Journal calls use `journal.record(...)` (`:888`). Add here: `private(set) var isMuted`, `setMuted(_:) async`, a live-output flag, dropped-chunk handling.
- `HermesRelay/Services/AudioOutput.swift` / `AppleAudioOutput.swift` -- `AudioOutput` protocol (`:196`); `start`/`append`/`stop` (`AppleAudioOutput:83,115,167`). `stop()` ends the stream and releases a pending `finish()` drain; the protocol does not change. `PCMFrameAccumulator` (`AudioOutput.swift:31`) re-frames chunks, so a resume after dropped bytes must realign to a frame boundary (see Design Notes).
- `HermesRelay/Views/RecentTranscriptRail.swift` -- `RecentTranscriptDisplay.entries` `:435` hides the live reply until `playbackPosition != nil`; `revealTarget` `:611` and `revealText` `:737` pace text. Muted must show streamed text (criterion 8). Pure function, unit-testable.
- `HermesRelay/Views/AmbientHUD.swift` -- status line `orbStatusLine` `:501`; control row under it `:594-623` (`HandsFreePill` is iOS only, `#if os(iOS)` `:610`); `AmbientHUDView` passes playback props to the rail `:902`. `HermesRelay/Views/VoiceControl.swift` -- `HandsFreePill` `:90` is the pattern for the new control; `orbAction` uses `hand.raised.fill` for Interrupt.
- `HermesRelay/Views/ContentView.swift` -- `ambientHUD` `:391` builds the HUD; `ContentViewRuntime` builds one coordinator per process (`:19-86`), so in-memory mute is sticky for the process and resets on launch.
- Tests: `HermesRelayTests/VoiceSessionCoordinatorTests.swift` (`CoordinatorAudioOutput` fake, `makeBackgroundVoiceHarness`, `harness.journal`); `HermesRelayTests/HermesRelayTests.swift` (HUD and rail pure tests).

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: same mute control, journal line and placement as iPad.
- Mute is process memory in the voice coordinator, never `@AppStorage` (criterion 5).

## Tasks & Acceptance

**Execution:**
- [ ] `VoiceSessionCoordinator.swift` -- add `isMuted`, `setMuted`; gate `.audioChunk` and file audio (drop, count bytes, set `audioDeliveryStarted`, `.speaking`); skip `output.finish()` when no output is live; resume with `start` plus frame realignment; muting mid-reply calls `output.stop()` only; one journal line per change -- criteria 2-6, 9, 10
- [ ] `VoiceControl.swift` -- `MuteButton` (glyph `speaker.slash.fill` muted / `speaker.wave.2` unmuted, labels "Mute Hermes"/"Unmute Hermes", toggle trait, one VoiceOver announcement per change, 44 pt hit area) -- criteria 1, 7
- [ ] `AmbientHUD.swift` -- show `MuteButton` beside the hands-free pill (both platforms) while connected; append "Muted" to the status line; pass `isMuted` to the rail -- criteria 1, 7, 8
- [ ] `RecentTranscriptRail.swift` -- when muted, show the live reply as it streams and keep `revealedTexts` in step so unmuting never retracts text -- criterion 8
- [ ] `VoiceSessionCoordinatorTests.swift`, `HermesRelayTests.swift` -- tests listed in Verification
- [ ] `spec-ios-ux-f8-mute.md`, `sprint-status.yaml` -- record the outcome, move status to review

**Acceptance Criteria (compact; large uses compact placement until F9):**
- Given a reply is streaming audio, when the user mutes, then output stops at once, no interrupt reaches the store, text keeps streaming, and the turn completes as `.complete`, never `.failed`.
- Given muted, when audio chunks and `audioEnd` arrive, then they are consumed and dropped, nothing is appended, and the reply ends without waiting on playback.
- Given muted, when a file-audio reply (`audioFileStart/Chunk/End`) arrives, then it is dropped and counts as delivered.
- Given muted and a second reply, then it is also silent; a new coordinator starts unmuted.
- Given a muted reply mid-stream, when the user unmutes, then later chunks play from the current point and dropped bytes are never replayed.
- Given muted, when the user taps Interrupt, then the turn ends as it does unmuted and mute stays on.
- Given any mute change, then exactly one journal line `voice output mute=on|off reply=playing|idle` is written (none when the value does not change), with no content.
- Given muted, then the status line shows "Muted" and the control reads "Unmute Hermes" with a toggle trait.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

- Drop point is the coordinator, not the output: `AppleAudioOutput` and its wrappers (`RecoveringAudioOutput`, `HomeAwareAudioOutput`, `AudioActivityReportingOutput`) stay unchanged, so the legacy WAV recovery never sees muted audio.
- Mute flips synchronously, then `await output.stop()`. A chunk handler already past the gate can race the stop: recheck `isMuted` after any awaited `start`, and treat an append that fails because mute stopped the output as dropped, not as a playback failure.
- Frame realignment: `streamedAudioBytes` counts every byte of the segment. On resume the first appended chunk skips `(bytesPerFrame - bytesBefore % bytesPerFrame) % bytesPerFrame` leading bytes, so 16-bit PCM is never read one byte off.
- "Playing" in the journal line means `state.isOutputActive` (buffering or speaking).
- Muting while idle changes only the flag and journal; the next reply is dropped from its first chunk and the output is never started.

## Verification

**Commands:**
- `xcodebuild … test` (iOS Simulator, CI command) -- expected: all tests pass, baseline 667 plus new.
- `xcodebuild … -destination 'platform=macOS' test` -- expected: all pass, baseline 666 plus new.

**Tests (fake output):** no interrupt while muted; chunks consumed, not appended; muted reply completes without playback failure (Standard and Home paths); sticky across replies; unmute resumes live and realigns an odd split; file-audio path dropped; Interrupt works muted; journal line once per change, none on no-op; rail shows streamed text while muted and does not retract after unmute; status line shows "Muted".

**Pending device:** mute mid-reply on speaker and headphones; VoiceOver labels and one announcement per change; other apps' audio and system volume untouched; large-window placement waits for F9.
