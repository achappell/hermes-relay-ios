---
title: 'IOS-UX-F9 — Propose the large-format whole-screen layout'
type: 'investigation'
created: '2026-10-07'
status: 'draft'
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

**One layout-class resolver.** The layout class is computed in exactly one place per app and read everywhere else; views never branch on platform or device. On macOS the resolver always returns large. (SDK check: `EnvironmentValues.horizontalSizeClass` is available on macOS 10.15+ per the macOS `SwiftUICore` swiftinterface in Xcode 27.2 beta 2, lines 22064-22066, but nothing there defines its value on macOS, so the resolver does not read it there.)

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

Re-checked against `origin/main` e58974f: one `ContentView` serves iPhone, iPad and Mac (`WindowGroup` at `HermesRelayApp.swift:139`). No view reads `horizontalSizeClass`, and the app has no `NavigationSplitView`, `.inspector`, `.commands` or `CommandMenu`; large windows get the phone layout (orb `AmbientHUD.swift:310`, recent rail `:887`, composer `ContentView.swift:543`, bottom bar width-capped at 760 pt `:585`, HUD at 900 pt `:632`). `userInterfaceIdiom` is not used either.

## Open Questions

PROVISIONAL decisions: the owner has not confirmed these. Work proceeds on them under the director's authorization; the owner corrects afterwards.

- Approval — criterion 6 needs the owner's written approval and its date. **This PR is a draft proposal; the spec stays `in-review`, never `done`, and no approval date is recorded until the owner approves.** Compact work in F6-F8 proceeds without waiting.
- One arrangement or two on large windows — options: one arrangement for voice and typing, orb always small beside the transcript (matches FB-TYPE criterion 10; **recommended and drafted**) / voice view keeps a large orb in the side panel and typing shrinks it. The proposal states both and recommends the first; the owner chooses.
- Keyboard shortcuts — the proposal drafts ⌘⇧L (talk or return to voice), ⌘L (focus composer), ⌘⇧M (mute), ⌘. (interrupt), ⌃⌘S (sidebar), ⌥⌘T (thinking pane) on Apple platforms, and Ctrl equivalents on Android. F7 builds ⌘⇧L ahead of approval. The owner approves or changes them.
- Android platform notes rest on Material adaptive guidance and the Android twin spec (`spec-android-ux-15-large-layout.md`), not on a build of the Android app; the Android repo's owner reviews them.

## Code Map

- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-large-layout-2026-10-10/LAYOUT.md` (new) -- the proposal; frontmatter `status: proposed`, approval block "pending".
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-large-layout-2026-10-10/mockups/large-layout.html` (new) -- offline static HTML and CSS in the style of `ux-hermes-relay-ios-2026-09-27/mockups/key-conversation.html` (inline CSS, system fonts, no JS, DESIGN.md tokens); frames for iPad, Mac and Android tablet, each in voice view, typing view, reply with thinking text, and mute on, plus a narrowing strip.
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md` and `EXPERIENCE.md` -- source of tokens, component names and the accessibility floor; read, not changed.
- `_bmad-output/implementation-artifacts/spec-ios-ux-f6-thinking-text.md`, `-f7-typing-view.md`, `-f8-mute.md` -- their large-format criteria point at the approved proposal; not edited here.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- `ios-ux-f9` moves to review when the PR opens.

## Tasks & Acceptance

**Execution:**
- [ ] Check the platform facts the proposal relies on and cite them: SwiftUI `NavigationSplitView`, `.inspector`, `.commands`/`CommandMenu`, `.keyboardShortcut`, `AccessibilityFocusState` from the Xcode 27.2 beta 2 swiftinterfaces (same method as the spec's SDK check); Material adaptive layout and `WindowSizeClass` from the Android developer documentation
- [ ] `LAYOUT.md` -- criteria 1-5 below as sections: shared layout classes and resolver; arrangement and zone table; per-platform mockup index; narrowing order; reading and focus order per platform; shortcut table; impact on the F6, F7 and F8 large criteria; open decisions; approval block
- [ ] `mockups/large-layout.html` -- the 12 frames and the narrowing strip
- [ ] `spec-ios-ux-f9-large-layout.md`, `sprint-status.yaml` -- link the proposal, record the open approval, move F9 to review

**Acceptance Criteria:**
- Given the proposal, then every platform (iPad, Mac, Android tablet or foldable) has a frame for voice view, typing view, reply with thinking text, and mute on.
- Given the proposal, then it places transcript, composer, small orb, mute, Interrupt, thinking pane, status line and optional sidebar, and states what collapses first when a window narrows (sidebar, then thinking pane into the compact area above the composer).
- Given the proposal, then iPad and Mac share one arrangement and each Android difference is named with its platform reason.
- Given the proposal, then screen-reader order, keyboard focus order and shortcuts are listed per platform.
- Given the proposal text, then it names no device model or idiom; only horizontal size class or `WindowSizeClass`, and macOS as always large.
- Given the PR, then it changes no Swift, project or test file.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

- The proposal builds on the starting wireframes in this spec and refines them; where it departs, it says why.
- Mockups use the existing Night Console tokens and fixed layout widths, not device frames of a named model.

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- iPad and Mac share one arrangement; Mac adds menu-bar commands for the shortcuts.
- The proposal and mockups are written once, here, under `_bmad-output/planning-artifacts/ux-designs/` (new dated folder, same pattern as `ux-hermes-relay-ios-2026-09-27`); the Android twin links to it.

## Verification

**Commands:**
- `python3 -m unittest discover -s tests` -- expected: the repo's issue-tracking checks pass.
- `git diff --name-only origin/main` -- expected: only `_bmad-output/` markdown, HTML and YAML.

**Manual checks:**
- Open `large-layout.html` in a browser: every frame renders offline, labels match `LAYOUT.md`.
- Owner review of the proposal; the approval date is recorded here by the owner.
