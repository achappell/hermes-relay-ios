---
title: 'IOS-UX-F6 — Make Hermes's thinking text readable'
type: 'experiment'
created: '2026-10-07'
status: 'backlog'
route: 'dispatch'
review_loop_iteration: 0
parity_tag: 'FB-THINK'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** While Hermes thinks, its reasoning text flashes across the bottom bar one fragment at a time and is gone before it can be read. The user wants to actually read it. The owner wants to try a transcript-row design and judge it in use.

**Approach:** An experiment: accumulate thinking text per turn in memory, show it as a collapsed row in the transcript, open it full-screen on tap (sheet on compact, pane on large), and announce it once to screen readers. Shared criteria below.

</frozen-after-approval>

## Scope

**Parity:** tag `FB-THINK`. iOS and macOS: `IOS-UX-F6` (hermes-relay-ios). Android: `ANDROID-UX-13` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

**One layout-class resolver.** The layout class is computed in exactly one place per app and read everywhere else; views never branch on platform or device. On macOS the resolver always returns large. (SDK check: `EnvironmentValues.horizontalSizeClass` is available on macOS 10.15+ per the macOS `SwiftUICore` swiftinterface in Xcode 27.2 beta 2, lines 22064-22066, but nothing there defines its value on macOS, so the resolver does not read it there.)

### Acceptance criteria (shared wording, FB-THINK)

**Experiment** (owner, 2026-10-07: "try it and see"). After the owner has used it, a follow-up review decides whether to keep, change or remove it; record the outcome in this spec.

1. Thinking text (`thinking.delta`, `reasoning.delta`, `reasoning.available`, and any `reasoning` carried on the completed message) accumulates in arrival order for the active turn. A new delta appends; it never replaces earlier thinking text.
2. Thinking text and status text are kept apart. A status update never overwrites or hides thinking text, and thinking text never appears inside the reply text.
3. Thinking appears as one collapsed row inside the transcript, in place for its turn (before that turn's reply). The row has a fixed height that does not grow, shrink or jump per delta, shows that Hermes is thinking or has thought, and stays in place when the reply arrives. It replaces the bottom-bar thinking line.
4. Tapping the row opens the full thinking text for that turn full-screen: a sheet or modal on compact; on large, a pane or panel placed by the approved FB-LAYOUT proposal (until approval, large windows use the compact sheet). While the turn is still thinking, the opened view accumulates live; it does not auto-scroll while the user has scrolled up. Closing it returns to the same transcript position.
5. Thinking text is held in memory only. It is never written to the stored transcript, so a relaunch or restored conversation shows no thinking rows for past turns.
6. Screen readers (VoiceOver, TalkBack) announce the row once when it appears ("Hermes is thinking"), never per delta. The accumulated text is read when the user opens the row, and the opened view is navigable line by line.
7. With Reduce Motion (iOS/macOS) or animations off (Android) the row and the opened view update without animated scrolling or expansion.
8. No thinking text reaches diagnostics, journal lines or logs. No Hermes protocol, Home or wire change.

### iOS and macOS today

Checked against `origin/main` (dda7181):
- **Verified:** `ConversationStore.swift:3074-3075` assigns each `.thinkingDelta(text)` to `activityText`, replacing the previous fragment; `:3076-3077` writes `.status` text into the same field, so status also overwrites thinking. `activityText` is declared at `:107` and is also set from the Home activity enum at `:1821`.
- `ConversationStore.swift:3087` ignores the `reasoning` field of `.messageComplete`, so reasoning sent only at completion is never shown.
- **Verified:** `ContentView.swift:487-496` shows `activityText` above the composer in the bottom safe-area inset (`:280-282`) as a `ProgressView` plus one `.footnote` line with `.lineLimit(1)` (`:491`); no accessibility treatment, so the line is replaced on every delta.
- Events reach it via `HermesEventNormalizer.swift:74-78` (Standard `thinking.delta`, `reasoning.delta`, `reasoning.available`) and `:194-197` (Home `thinking`/`reasoning` activity, `HomeBridgeModels.swift:980-981`); `VoiceSessionCoordinator.swift:1323-1325` moves the voice state to `.thinking`.
- macOS: same `ContentView` in the same `WindowGroup` (`HermesRelayApp.swift:139`); no view under `HermesRelay/Views` reads `horizontalSizeClass` today.

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: a Mac window is large; the opened thinking view is the FB-LAYOUT pane, identical to iPad.
- The row replaces `ContentView.swift:487-496`; accumulated text lives beside `messages` in `ConversationStore`, not in `TranscriptMessage` persistence.

## Verification

- Focused XCTest: deltas append in order; status never overwrites thinking; completion-only reasoning shown; nothing persisted.
- Full iOS Simulator suite and macOS build.
- On device: a long-thinking turn on iPhone (row and opened sheet), VoiceOver (one announcement, readable when opened) and Reduce Motion.
