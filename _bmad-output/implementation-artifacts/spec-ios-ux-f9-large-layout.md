---
title: 'IOS-UX-F9 — Propose the large-format whole-screen layout'
type: 'investigation'
created: '2026-10-07'
status: 'backlog'
route: 'dispatch'
review_loop_iteration: 0
parity_tag: 'FB-LAYOUT'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** iPad, Mac and Android large screens show the phone layout stretched or width-capped. The large-format behaviour of FB-THINK, FB-TYPE and FB-MUTE needs one approved whole-screen layout first.

**Approach:** An investigation that produces one whole-screen proposal with mockups for the owner to approve. Compact criteria elsewhere stay buildable now.

</frozen-after-approval>

## Scope

**Parity:** tag `FB-LAYOUT`. iOS and macOS: `IOS-UX-F9` (hermes-relay-ios). Android: `ANDROID-UX-15` (hermes-relay-android). The acceptance criteria below are worded identically in both repos; only the platform notes differ. Mac and iPad stay the most alike.

**Layout classes (shared by FB-THINK, FB-TYPE, FB-MUTE, FB-LAYOUT).** *Compact* is a window whose horizontal size class is compact: iPhone, and an Android phone (`WindowWidthSizeClass` Compact). *Large* is a window whose horizontal size class is regular: iPad, Mac, and Android tablets and unfolded foldables (`WindowWidthSizeClass` Medium or Expanded). The class comes from the window's size class (SwiftUI `horizontalSizeClass`, Android `WindowSizeClass`), never from a device model or idiom check. A window that changes class (Split View, Stage Manager, window resize, fold or unfold, rotation) switches layout without losing the draft, the transcript scroll position or screen-reader focus.

### Acceptance criteria (shared wording, FB-LAYOUT)

1. One written whole-screen proposal covers the large layout class on iPad, Mac and Android tablets and foldables, with a mockup per platform in voice view and typing view, during a reply with thinking text, and with mute on.
2. It places the transcript, composer, small orb, mute, Interrupt, thinking pane, status line and an optional conversations sidebar, and says what collapses when a large window narrows toward compact.
3. iPad and Mac use the same arrangement; Android large follows it, differing only where a platform convention requires (noted per item).
4. It gives screen-reader reading order, keyboard focus order and the keyboard shortcuts for voice/typing and mute on each platform.
5. It uses only the shared layout classes; nothing in it depends on device model or idiom.
6. The owner approves it in writing (date recorded in this spec); the large-format criteria of FB-THINK, FB-TYPE and FB-MUTE then follow it. Compact criteria do not wait for it.

### Starting wireframes (for the proposal to refine; not approved)

Compact (iPhone, Android phone), typing view:

```
+----------------------------------+
| Profile · Connected       [Mute] |
| transcript (full, compact)       |
|  You: ...                        |
|  Hermes: ...                     |
|                                  |
| [v] Thinking · latest 3 lines    |
| [o] [ Message Hermes...   ][Send]|
+----------------------------------+
  [o] = small voice control (returns to voice)
```

Large (iPad, Mac, Android tablet or unfolded foldable):

```
+-------------+--------------------------------+------------------+
| Conversa-   | Profile · Connected · 02:14    | Thinking         |
| tions       |                                | (accumulating,   |
| (optional,  | transcript (full, compact)     |  scrollable,     |
|  sidebar)   |  You: ...                      |  per turn)       |
|             |  Hermes: ...                   |                  |
|             |                                |------------------|
|             |                                | (o) orb, small   |
|             | [ Message Hermes...     ][Send]| [Mute] [Interrupt|
+-------------+--------------------------------+------------------+
```

Narrowing toward compact: the sidebar collapses first, then the thinking pane becomes the compact thinking area above the composer.

### iOS and macOS today

Checked against `origin/main` (dda7181): one `ContentView` serves iPhone, iPad and Mac (`HermesRelayApp.swift:139`). No view reads `horizontalSizeClass` and there is no `NavigationSplitView`; large windows get the phone layout (orb `AmbientHUD.swift:305-326`, recent rail `:887-916`, composer `ContentView.swift:543`).

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- iPad and Mac share one arrangement; Mac adds menu-bar commands for the shortcuts.
- Mockups live with the proposal under `_bmad-output/planning-artifacts/ux-designs/` (new dated folder, same pattern as `ux-hermes-relay-ios-2026-09-27`).

## Verification

- Owner review of the proposal and mockups; approval date recorded here.
- No code; no test run beyond the repo's issue-tracking checks.
