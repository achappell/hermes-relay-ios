---
title: 'IOS-UX-F7 — Switch to a typing-focused view when the composer is focused'
type: 'feature'
created: '2026-10-07'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
parity_tag: 'FB-TYPE'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The app opens in the voice view with a large orb. When the user wants to type, the orb keeps most of the screen and the transcript is a short recent rail. Typing should feel like a focused terminal session for reading and writing (TUI feel, not TUI features), while voice stays the default.

**Approach:** Keep the voice view as the launch default; focusing the composer switches to a typing view; the voice control returns to voice and starts listening. The return-to-voice rule is decided: (a) + (d).

</frozen-after-approval>

## Scope

**Parity:** tag `FB-TYPE`. iOS and macOS: `IOS-UX-F7` (hermes-relay-ios). Android: `ANDROID-UX-14` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

**One layout-class resolver.** The layout class is computed in exactly one place per app and read everywhere else; views never branch on platform or device. On macOS the resolver always returns large. (SDK check: `EnvironmentValues.horizontalSizeClass` is available on macOS 10.15+ per the macOS `SwiftUICore` swiftinterface in Xcode 27.2 beta 2, lines 22064-22066, but nothing there defines its value on macOS, so the resolver does not read it there.)

### Acceptance criteria (shared wording, FB-TYPE)

1. The app still opens in the voice view on every launch.
2. Focusing the composer (tap, or a hardware-keyboard focus or first keystroke) switches to the typing view: the transcript and the composer are front and centre, and the large orb shrinks to a small voice control. The draft, scroll position and recent prompts are unchanged.
3. The typing view shows the conversation as a full scrollable transcript at compact density (tighter spacing, no decorative chrome), newest at the bottom, anchored above the composer. The keyboard never covers the newest message or the composer.
4. One tap on the small voice control, or one keyboard shortcut on a hardware keyboard, returns to the voice view, dismisses the keyboard and starts listening immediately. If microphone permission is not yet granted, the existing permission flow runs first and listening starts only once it is granted; if it is denied, the voice view shows the existing permission state and nothing is captured.
5. Neither transition moves transcript content except for the space the orb gives up or takes back. With Reduce Motion or animations off the switch is instant.
6. Screen-reader focus stays in the composer when the typing view opens and moves to the voice control when the voice view returns; nothing else is announced.
7. The typing view adds no TUI features: no slash commands, monospace mode, key-chord editing or command palette.
8. The typing view stays until the user returns to voice explicitly: by tapping the voice control (criterion 4), by a voice shortcut (Siri or App Shortcut, Android assistant or app shortcut), or by a hands-free wake when hands-free is already armed. A voice shortcut or wake returns to the voice view, dismisses the keyboard and leaves the voice action it triggered running.
9. The typing view never returns to voice on its own: not when the composer is empty and loses focus, not when the keyboard is dismissed by scrolling or tapping the transcript, and not after any idle time.
10. Large: the transcript and composer are always visible, the orb is a small toolbar or side control, and a conversations sidebar may be shown, as placed by the approved FB-LAYOUT proposal. Until that proposal is approved, large windows use the compact behaviour.

### Decision: when to return to voice (owner, 2026-10-07)

Adopted **(a) + (d)**: stay in the typing view until the voice control is tapped, or the user starts voice another explicit way (voice shortcut, or hands-free wake when already armed). Criteria 8 and 9.

| Option | Layout jumps | One action to voice | Keyboard dismissal | Screen-reader focus continuity | Decision |
|---|---|---|---|---|---|
| (a) Stay until the voice control is tapped | None unprompted | Yes, the voice control | User-driven (swipe, tap transcript, send) | Best: focus never moves on its own | Adopted |
| (b) Composer empty and blurred | Frequent: scrolling or tapping the transcript dismisses the keyboard, which blurs an empty composer and flips the view while the user reads | Yes, but it also fires by accident | Coupled to the switch, so reading closes typing | Poor: focus is pulled to the orb mid-read | Rejected |
| (c) Idle N seconds | Unprompted jump while the user is reading a long reply | Yes, but timed | Keyboard drops on a timer | Poor: focus moves with no user action | Rejected |
| (d) Voice shortcut or hands-free wake | Only on an explicit voice action | Yes, the shortcut itself | Dismissed by the deliberate switch | Good: the user caused the move | Adopted |

(b) and (c) are rejected because both turn reading the transcript, which the typing view exists for, into an accidental switch, and both move screen-reader focus without a user action.

## Open Questions

PROVISIONAL decisions: the owner has not confirmed these. Work proceeds on them under the director's authorization; the owner corrects afterwards.

- Dependency on `IOS-UX-F9` — options: ignore F9 for compact work; iPad and Mac use the compact typing view until F9 is approved, so no layout-class resolver is built here (F9 owns it) / wait for F9 (nothing ships). **Provisional: ignore F9.** `story-index.yaml` still lists `ios:IOS-UX-F9` as a dependency although this spec says compact criteria build now; the index is left unedited.
- Reply text in the typing view — options: show streamed text live as it arrives (reading is the point of this view) / reveal it in step with speech as the voice rail does (IOS-UX-F5). **Provisional: live.**
- First keystroke focusing the composer (criterion 2, hardware keyboard) — options: build with `.onKeyPress` on a focusable container (needs a hardware keyboard to verify; risks stealing focus) / cover tap and keyboard focus only now. **Provisional: tap and keyboard focus only**; first-keystroke is deferred and recorded in the PR.
- Voice-shortcut return (criterion 8; Siri or App Shortcut) — the app has no App Intent or App Shortcut today (`grep AppIntent` finds none). **Provisional: not applicable until one exists.** The hands-free wake path is built through the voice state change, which a future shortcut also drives.
- Keyboard shortcut for return to voice (criterion 4) — the FB-LAYOUT proposal chooses it and F9 is unapproved. **Provisional: ⌘⇧L**, the binding the F9 proposal draft uses; one line to change.
- macOS may focus the composer when the window opens, which would break criterion 1. **Provisional: ignore focus changes until the first user interaction after launch**; confirm on a Mac.

## Code Map

Verified against `origin/main` e58974f. Line numbers move when IOS-UX-F8 lands under this branch.

- `HermesRelay/Views/ContentView.swift` -- `@FocusState focusedField` `:116` (only `.composer`); body `:242-327`: one `ScrollView` always present because swapping it in on focus counted as a scroll and dismissed the keyboard (`:244-254`) — keep one scroll view and swap its content; bottom inset `:280` (`bottomSurface` `:578`, `composer` `:474`, `TextField` `:543`, Send `:562`); `sendDraftIfPossible` `:625` blurs the composer; `recentPromptsMenu` `:451`. `shouldShowVoiceInterface` `:214` and `VoiceControlInteractionPolicy.isVisible` are unused outside tests.
- `HermesRelay/Views/AmbientHUD.swift` -- `AmbientHUDView.body` `:557-635` stacks header, notices (cached `:637`, unconfirmed turn, Home status, recovery, failure), `CompressibleOrb` (260 pt) `:578`, status line, pill, `captionArea` `:887` (rail). The notices must stay reachable in the typing view. `VoiceOrbButton` `:968` is private; the tap path is `VoiceControlInteractionPolicy.performPrimaryAction` (`VoiceControl.swift:73`), which handles permission failures through `VoiceState.failed(.permission)`.
- `HermesRelay/Views/AmbientHUD.swift:1140` `TranscriptHistoryView` and `MessageBubble.swift` -- the only full-transcript rendering today (sheet); its rows are the pattern, with a context menu to copy or share.
- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift` -- `state`, `isHandsFreeArmed`, `isHandsFreeCaptureActive`, `beginCapture` `:777`; a hands-free wake or any voice action moves `state` to `.listening` or `.transcribing`.
- F8 (this branch's base): `MuteButton` and `isMuted`. The typing view shows the mute control with the small voice control.
- Tests: `HermesRelayTests/HermesRelayTests.swift` (pure policy tests such as `VoiceControlInteractionPolicy` at `:216`).

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: a Mac window is large; the keyboard shortcut in criterion 4 is the Mac path (shortcut chosen in the FB-LAYOUT proposal). iPad with a hardware keyboard uses the same shortcut.
- Criterion 4 reuses the orb's existing tap-to-talk path (IOS-UX-F5), including its permission handling.
- iOS keyboard: the typing view sits above the keyboard via the existing safe-area inset; no new keyboard handling.

## Tasks & Acceptance

**Execution:**
- [ ] `Views/ConversationViewMode.swift` (new) -- `ConversationViewMode` (`voice`, `typing`) and a pure reducer: launch is voice; composer focus enters typing; blur never leaves; voice-control tap, hands-free wake or listening start returns to voice -- criteria 1, 2, 8, 9
- [ ] `ContentView.swift` -- `@State viewMode` driven by the reducer (focus change, voice state change); keep one `ScrollView`; typing content anchored at the bottom (`.defaultScrollAnchor`) and top in voice; animation off under Reduce Motion; `@AccessibilityFocusState` to the composer on entering typing and to the voice orb on return; draft and `store` untouched by the switch -- criteria 2, 3, 5, 6
- [ ] `AmbientHUD.swift` -- take the view mode; in typing, keep the header and notices, drop the orb, status line, pill and rail, show `TypingTranscriptView` and the mute control -- criteria 2, 3
- [ ] `Views/TypingTranscriptView.swift` (new) -- full `store.messages`, compact density (tight spacing, no panel chrome), newest at the bottom, scrolls to newest on arrival and when the keyboard shows; keeps copy and share -- criterion 3
- [ ] `VoiceControl.swift` -- `SmallVoiceControl` (44 pt): glyph and hint from `orbAction`, tap sets voice view, blurs the composer, then runs `performPrimaryAction`; shortcut ⌘⇧L; accessible name "Voice" -- criteria 4, 6
- [ ] `HermesRelayTests.swift` -- reducer and tap-path tests listed in Verification
- [ ] `spec-ios-ux-f7-typing-view.md`, `sprint-status.yaml` -- record outcome, move status to review

**Acceptance Criteria (compact; large uses compact until F9):**
- Given a fresh launch, then the voice view shows; focusing the composer shows the typing view with the draft and recent prompts unchanged.
- Given the typing view, when the composer loses focus (keyboard dismissed, transcript tapped or scrolled, send, idle time), then the typing view stays.
- Given the typing view, when the small voice control is tapped with microphone permission granted, then the voice view shows, the keyboard is dismissed and capture begins; not determined runs the existing permission prompt first; denied shows the existing permission state and captures nothing.
- Given the typing view and hands-free armed, when a wake starts capture, then the voice view shows and capture continues.
- Given a reply streaming in the typing view, then text appears live and the transcript stays anchored above the composer and the keyboard.
- Given Reduce Motion, then the switch is instant.

## Implementation Notes

Implemented 2026-10-10 on `feat/ios-ux-f7-typing-view` (stacked on F8), compact scope only.

- `ConversationViewMode` + pure `ConversationViewModeReducer`: launch is voice; composer focus enters typing; blur, send, idle never leave; voice-control tap or a capture starting (hands-free wake) returns to voice.
- `ContentView`: one `ScrollView` kept (content swapped inside `AmbientHUDView`); `defaultScrollAnchor(.bottom)` plus `scrollTo` on mode, message count and keyboard focus changes; `@AccessibilityFocusState` moves focus to the composer on entering typing and to the orb on return; animation off under Reduce Motion; focus changes are ignored for the first 500 ms so a Mac window that auto-focuses the composer still opens in voice view.
- `AmbientHUDView` typing content keeps the header and the cached, unconfirmed-turn and Home notices, plus recovery and failure notices, and the F8 `MuteButton` with a status line that shows "Muted". Orb, hands-free pill and reply rail are replaced by `TypingTranscriptView` (compact rows, copy/share kept, empty replies skipped).
- `SmallVoiceControl`: button left of the composer, glyph and hint from `orbAction`, switches to voice, blurs the composer, then runs `performPrimaryAction` (existing permission handling). Shortcut ⌘⇧L is PROVISIONAL pending IOS-UX-F9.
- Not built: first-keystroke focus, voice-shortcut return (no App Intents exist). Reply text in the typing view shows live.

## Verification record

- iOS Simulator: 687 tests, 0 failures (baseline 667; F8 +14; F7 +6). macOS: 686 tests, 0 failures (baseline 666). No reruns needed.
- Tests are pure (reducer, status line, transcript filter); the SwiftUI wiring (keyboard, scroll, VoiceOver focus) is pending-device.

## Spec Change Log

## Review Triage Log

## Design Notes

- The mode is its own state; focus is only a trigger. Deriving the mode from `focusedField` would make a dismissed keyboard flip the view (rejected options (b) and (c)).
- Return order: set `.voice`, blur the composer, then start the voice action, so a denied permission lands on the voice view's existing permission state.
- Swapping the outer `ScrollView` on focus dismisses the keyboard (`ContentView.swift:244-254`); only its content changes.

## Verification

**Commands:**
- `xcodebuild … test` (iOS Simulator, CI command) -- expected: all pass, baseline 667 plus F8's and new.
- `xcodebuild … -destination 'platform=macOS' test` -- expected: all pass, baseline 666 plus F8's and new.

**Tests (pure):** launch is voice; focus enters typing; blur and send stay typing; tap returns voice in every permission case; a wake or listening start returns voice; the reducer carries no draft or scroll state.

**Pending device:** iPhone software keyboard keeps newest message and composer visible and the switch does not dismiss the keyboard; iPad hardware-keyboard focus and ⌘⇧L; Mac window opens in voice view; VoiceOver focus moves to the composer, then to the orb, with nothing else announced; Reduce Motion.
