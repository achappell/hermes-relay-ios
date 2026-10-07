---
title: 'IOS-UX-F6 — Make Hermes's thinking text readable'
type: 'feature'
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

**Problem:** While Hermes thinks, its reasoning text flashes across the bottom bar one fragment at a time and is gone before it can be read. The user wants to actually read it.

**Approach:** Accumulate thinking text per turn in its own state, show it in a stable readable area (expandable on compact, a dedicated pane on large), and keep screen readers quiet per delta. Shared criteria below.

</frozen-after-approval>

## Scope

**Parity:** tag `FB-THINK`. iOS and macOS: `IOS-UX-F6` (hermes-relay-ios). Android: `ANDROID-UX-13` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

### Acceptance criteria (shared wording, FB-THINK)

1. Thinking text (`thinking.delta`, `reasoning.delta`, `reasoning.available`, and any `reasoning` carried on the completed message) accumulates in arrival order for the active turn. A new delta appends; it never replaces earlier thinking text.
2. Thinking text and status text are kept apart. A status update never overwrites or hides thinking text, and thinking text never appears inside the reply text.
3. Compact: thinking text sits in one stable area between the transcript and the composer. Collapsed, it shows the latest three lines at a fixed height that does not grow, shrink or jump per delta. One tap expands it into a scrollable view of the whole thinking text for the turn; one tap collapses it again. Expanded, it does not auto-scroll while the user has scrolled up.
4. Large: thinking text uses a dedicated thinking pane placed by the approved FB-LAYOUT proposal. Until that proposal is approved, large windows use the compact behaviour.
5. When the turn ends (complete, interrupted or failed), that turn's thinking text stays available, collapsed, until the next turn starts. It is held in memory only and is not written to the stored transcript.
6. Screen readers (VoiceOver, TalkBack) do not announce individual deltas. Thinking starting is announced once ("Hermes is thinking"); the accumulated text is read when the user focuses the thinking area, and the expanded view is navigable line by line.
7. With Reduce Motion (iOS/macOS) or animations off (Android) the area updates without animated scrolling or expansion.
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
- macOS: same compact/large rules; a Mac window is large. The thinking pane follows the approved FB-LAYOUT proposal, identical to iPad.
- Size class: macOS has no compact horizontal size class [INFERENCE: `horizontalSizeClass` is not usable on macOS]; resolve the layout class once in one place (regular on macOS) rather than branching in each view.

## Verification

- Focused XCTest: deltas append in order; status never overwrites thinking; completion-only reasoning shown; cleared when the next turn starts.
- Full iOS Simulator suite and macOS build.
- On device: a long-thinking turn on iPhone (collapsed and expanded), VoiceOver (one announcement, readable on focus) and Reduce Motion.
