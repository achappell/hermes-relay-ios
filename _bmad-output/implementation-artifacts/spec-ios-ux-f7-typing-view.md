---
title: 'IOS-UX-F7 — Switch to a typing-focused view when the composer is focused'
type: 'feature'
created: '2026-10-07'
status: 'backlog'
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

### iOS and macOS today

Checked against `origin/main` (dda7181):
- `ContentView.swift:255-270`: the ambient HUD always fills the scroll view; `isComposing` (`:256`) only changes tap-to-dismiss-keyboard. The composer `TextField` is `:543-544` in the bottom inset (`:280-282`).
- `AmbientHUD.swift:305-326` (`CompressibleOrb`): the orb is drawn at 260 pt and only shrinks to 60% when height is short, not when typing.
- `AmbientHUD.swift:887-916`: the HUD shows a `RecentTranscriptRail` (recent entries); the full transcript is only in the `TranscriptHistoryView` sheet (`AmbientHUD.swift:1140`).
- macOS: the same `ContentView`; no size-class handling anywhere in `HermesRelay/Views`.

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: a Mac window is large; the keyboard shortcut in criterion 4 is the Mac path (shortcut chosen in the FB-LAYOUT proposal). iPad with a hardware keyboard uses the same shortcut.
- Criterion 4 reuses the orb's existing tap-to-talk path (IOS-UX-F5), including its permission handling.
- iOS keyboard: the typing view sits above the keyboard via the existing safe-area inset; no new keyboard handling.

## Verification

- Focused XCTest or UI test: launch in voice view; composer focus enters typing view; one action returns and starts listening (permission granted, not determined, denied); draft and scroll kept; VoiceOver focus targets.
- Full iOS Simulator suite and macOS build.
- On device: iPhone with software keyboard, iPad with hardware keyboard, VoiceOver.
