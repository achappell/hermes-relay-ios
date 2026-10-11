---
title: 'Large-format whole-screen layout (FB-LAYOUT)'
status: proposed
approval: pending
parity_tag: 'FB-LAYOUT'
stories: ['IOS-UX-F9', 'ANDROID-UX-15']
created: '2026-10-10'
tokens: '../ux-hermes-relay-ios-2026-09-27/DESIGN.md'
mockups: 'mockups/large-layout.html'
---

# Large-format whole-screen layout

**Status: proposed; owner approval required. Nothing here is approved.** Keyboard shortcuts are proposals. Approval date: pending.

This is the one written proposal required by `spec-ios-ux-f9-large-layout.md` (iOS and macOS) and its Android twin `ANDROID-UX-15`. It refines the starting wireframes in that spec; where it departs, it says why. Tokens, component names and the accessibility floor come from `ux-hermes-relay-ios-2026-09-27/DESIGN.md` and `EXPERIENCE.md`. Mockups: [`mockups/large-layout.html`](mockups/large-layout.html) (12 frames and a narrowing strip, offline).

## 1. Layout classes and the single resolver

Restated from the shared specs; nothing new is decided here.

- *Compact*: horizontal size class compact (iPhone; Android `WindowWidthSizeClass` Compact). *Large*: horizontal size class regular (iPad, Mac; Android `WindowWidthSizeClass` Medium or Expanded).
- The class comes from the window's size class, never from a device model or idiom check. Nothing in this proposal depends on either; Split View, Stage Manager, window resize, fold/unfold and rotation just change the class.
- The class is computed in exactly one resolver per app and read everywhere else. **macOS always resolves to large.** On iOS and Android the resolver reads the window size class.
- A class change swaps layout without losing the draft, transcript scroll position or screen-reader focus (shared spec wording).

### Verified platform facts

SDK facts are from the swiftinterfaces of Xcode 27.2 beta 2 (`DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer`). Paths are under `Platforms/<MacOSX|iPhoneOS>.platform/Developer/SDKs/<..>.sdk/System/Library/Frameworks/`; "mac" = `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`, "ios" = `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`, "mac-core"/"ios-core" = the same path under `SwiftUICore.framework/.../SwiftUICore.swiftmodule/` with `arm64e-apple-macos` / `arm64e-apple-ios`.

| Fact | Evidence (file:line of declaration) |
|---|---|
| `NavigationSplitView` is iOS 16 / macOS 13+ | mac:27624, ios:27086 (`@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)` three lines above) |
| `.inspector(isPresented:content:)` is iOS 17 / macOS 14+; unavailable on watchOS, tvOS, visionOS | mac:15158, ios:14713 |
| `Scene.commands { }` and `CommandMenu` are iOS 14 / macOS 11+ | `.commands` mac:17807, ios:17378; `CommandMenu` mac:22023 (`@available(iOS 14.0, macOS 11.0, *)`), ios:21473 |
| `.keyboardShortcut(_:modifiers:)` is iOS 14 / macOS 11+ (default modifier `.command`) | mac:27475, ios:26937 |
| `AccessibilityFocusState` and `.accessibilityFocused(_:)` are iOS 15 / macOS 12+ | `AccessibilityFocusState` mac:28040, ios:27502; `.accessibilityFocused` mac:28097, ios:27559 |
| `EnvironmentValues.horizontalSizeClass` is iOS 13 / macOS 10.15+, back-deployed before macOS 14; the interface does not define its value on macOS | mac-core:22066, ios-core:22037 (macOS lines already cited by the shared spec as 22064-22066) |

Android facts, from official Android developer documentation (read 2026-10-10):

- Window size classes: Compact width < 600 dp; Medium 600 dp to < 840 dp; Expanded 840 dp to < 1200 dp (Large and Extra-large added for desktop-type displays). They describe the window, are "explicitly not determined by the size of the device screen", are "not intended for isTablet-type logic", and change during the app's lifetime (rotation, multi-window, fold/unfold). Compute with `currentWindowAdaptiveInfo().windowSizeClass`. Source: <https://developer.android.com/develop/adaptive-apps/guides/use-window-size-classes>
- Canonical layouts: list-detail shows both panes only at Expanded width and one pane at Medium or Compact (when an Expanded window narrows, the detail stays and the list hides); supporting pane puts secondary content beside the main content at Medium and Expanded (equal split at Medium, 70/30 at Expanded) and below or in a bottom sheet at Compact. Source: <https://developer.android.com/develop/ui/compose/layouts/adaptive/canonical-layouts>
- Material 3 window size classes guidance is the origin of the Compact/Medium/Expanded breakpoints (linked from the page above): <https://m3.material.io/foundations/layout/applying-layout/window-size-classes>

[INFERENCE] items are marked inline and listed in section 11.

## 2. Arrangement and zone table

Three vertical regions, left to right: optional **conversations sidebar**, **main column** (status line, transcript, composer), **side panel** (thinking pane over the voice cluster). This keeps the starting wireframe; the one refinement is that the status line is in the main column header (it carries "Ready", "Thinking", "Speaking", "Muted") and the voice cluster is a single row at the bottom of the side panel.

```
+-------------+--------------------------------+------------------+
| Conversa-   | Profile · Connected · 02:14    | Thinking         |
| tions       | status: Ready · Typing         | (accumulating,   |
| (optional)  |--------------------------------|  scrollable,     |
|             | transcript (full, compact)     |  per turn)       |
|             |  You: ...                      |                  |
|             |  Hermes: ...                   |                  |
|             |  > Thinking · turn 3 (row)     |                  |
|             |--------------------------------|------------------|
|             | [ Message Hermes...     ][Send]| (o) [Mute][Interr]|
+-------------+--------------------------------+------------------+
```

| Zone | Placement on large | Notes |
|---|---|---|
| Transcript | Main column, fills height between header and composer; compact density, newest at bottom | Keeps F6's collapsed Thinking row in place for each turn. |
| Composer | Main column, pinned to the bottom; always visible | Never covered by the on-screen keyboard (F7 criterion 3). |
| Small orb | Side panel, voice cluster, left of Mute | Always small on large (see section 3). One tap, or the shortcut, talks or sends; glyph and "State · Action" semantics from DESIGN.md. |
| Mute | Side panel, voice cluster, between orb and Interrupt | Speaker glyph, label Mute/Unmute; muted = speaker-slash glyph, filled `attention`, and "Muted" in the status line. Never the Interrupt glyph or label (F8 criterion 1). |
| Interrupt | Side panel, voice cluster, rightmost | Square stop glyph, label Interrupt, `unavailable` colour. Dimmed when no reply is active; works while muted. |
| Thinking pane | Side panel, top, fills the height above the cluster | Shows the accumulated thinking text for one turn (the turn whose transcript row was opened; default the latest). Live, scrollable, no auto-scroll while the user has scrolled up. |
| Status line | Main column header, right end | "Phase · Action" per EXPERIENCE.md; shows Muted. Header also holds profile, connection, elapsed time. |
| Conversations sidebar | Left, optional, user-toggled | Hidden by default only where width demands (section 5); toggle sits at the header's left when hidden. |

Widths (proposal, adjust at build): sidebar about 170 pt, side panel about 230 pt to 320 pt, main column takes the rest. [INFERENCE] these numbers are untested against real type sizes.

Implementation hints, not requirements. Apple: sidebar = `NavigationSplitView` (two-column: sidebar + detail); thinking pane = `.inspector(isPresented:)` on the detail (mac and iOS 17+/macOS 14+, see facts above), with the voice cluster pinned in the inspector's lower area or the detail's toolbar [INFERENCE: not prototyped; the inspector's compact-class behaviour is not documented in the swiftinterface, so the resolver, not the inspector, decides when the pane becomes the compact area]. Android: `SupportingPaneScaffold` for the side panel and a navigation drawer or rail for the sidebar [INFERENCE: not built; owner of the Android repo to confirm].

## 3. Recommendation: one arrangement for voice and typing

**Recommended (drafted in all 12 frames):** one arrangement for both views. The orb is always small and lives in the voice cluster beside Mute and Interrupt. Voice view and typing view differ only by where focus is and the status line text; nothing moves between them.

Why: it matches F7 criterion 10 (large: orb is a small side control, transcript and composer always visible); with an always-visible transcript there is no space reason for a large orb; it removes a layout switch on the most frequent transition (talk, type, talk); and focus and reading order stay identical in both views.

**Alternative (owner choice):** *voice view keeps a large orb in the side panel* (about 260 pt as in the compact HUD) and typing view shrinks it to the small control. Gain: the orb remains the strong hero in voice view, as on compact. Cost: the side panel changes content at every transition; the thinking pane has to give up its height in voice view; two arrangements to build, test and describe; focus order differs per view. The spec's Open Questions list this choice for the owner.

## 4. Mockup index

All frames are in `mockups/large-layout.html`, fixed CSS widths, no device models, neutral text. Frame numbers match the captions in the file.

| Platform | Voice view | Typing view | Reply with thinking text | Mute on |
|---|---|---|---|---|
| iPad | 1 | 2 | 3 (sidebar hidden) | 4 (sidebar hidden) |
| Mac | 5 | 6 | 7 | 8 |
| Android tablet / foldable | 9 (Expanded) | 10 (Expanded) | 11 (Medium, sidebar collapsed) | 12 (Medium, sidebar collapsed) |

The strip at the bottom of the file shows the four narrowing stages (section 5). iPad frames 3 and 4 show the sidebar hidden to exercise the toggle. Mac frames show the menu-bar hint. Android frames 11 and 12 use a Medium width to show the platform difference in section 7.

## 5. Narrowing toward compact

Order, from a large window getting narrower (and the reverse when widening):

1. **Sidebar collapses first.** It becomes a header toggle; when opened it overlays the main column (Apple: sidebar column visibility; Android: modal drawer). Android: because list-detail shows one pane at Medium (source above), the sidebar is collapsed by default at Medium and shown at Expanded.
2. **Thinking pane becomes the compact thinking area above the composer** (latest 3 lines, one row), and the opened full text uses the compact sheet or modal (F6 compact criterion 4). The user's chosen turn, scroll position and any open pane state survive the change.
3. **Voice cluster folds into the compact controls** (resolver returns compact): the small orb joins the composer row (F7), Mute moves to the header's right (F8 compact placement: next to the voice control), Interrupt shows in the status line while a reply runs (current behaviour).

What does not collapse: transcript, composer, status line. Draft, transcript scroll position and screen-reader focus are kept across every step. At each step the order above is the only change; stages 1 and 2 may be reached separately on width alone because the resolver has only two classes: [INFERENCE] the sidebar toggle and pane visibility inside large are width-driven choices local to the large layout, and the resolver stays compact/large only.

## 6. Reading order, focus order, shortcuts

### Screen-reader reading order (VoiceOver, TalkBack)

Same on every platform: 1) conversations sidebar if shown (toggle if hidden), 2) status line (profile, connection, elapsed, phase, Muted), 3) transcript, oldest to newest, each turn's collapsed Thinking row after its question, 4) thinking pane (headed "Thinking, turn N"), 5) composer, 6) voice cluster: orb, Mute, Interrupt.

Rules: the Thinking row is announced once when it appears, never per delta; the pane's text is read only when the user moves into it (F6 criterion 6). Mute announces "Mute Hermes" / "Unmute Hermes" and its new state once per change (F8 criterion 7). Initial focus follows F7 criterion 6: composer when the typing view opens, orb when voice returns. Verified API for focus: `AccessibilityFocusState` and `.accessibilityFocused` (facts table).

### Keyboard focus order (Tab, Shift-Tab)

Sidebar toggle or sidebar list, transcript (a single scroll region; arrow keys scroll), thinking pane (scroll region), composer, Send, orb, Mute, Interrupt (skipped while dimmed). The status line is not focusable. First focus on window open: orb (voice view is the default); typing focus goes to the composer.

### Shortcut table (PROPOSALS, owner approval required)

| Action | iPad and Mac | Android (Ctrl equivalent) | Platform note |
|---|---|---|---|
| Talk, or return to voice from typing | ⌘⇧L | Ctrl+Shift+L | F7 builds ⌘⇧L provisionally ahead of approval. |
| Focus composer | ⌘L | Ctrl+L | [INFERENCE] Ctrl+L may collide with browser or ChromeOS address-bar conventions; Android owner to check. |
| Mute / unmute | ⌘⇧M | Ctrl+Shift+M | |
| Interrupt | ⌘. | Ctrl+. | ⌘. is the common Apple "cancel" chord. [INFERENCE] |
| Show/hide conversations sidebar | ⌃⌘S | Ctrl+Alt+S | Ctrl alone is the Android primary modifier on hardware keyboards [INFERENCE]; ⌃⌘ maps to Ctrl+Alt. |
| Show/hide thinking pane | ⌥⌘T | Ctrl+Alt+T | Same mapping. [INFERENCE] collisions with launcher or shell shortcuts unchecked. |

- **iPad and Mac share one set.** The shortcuts are declared once with `.keyboardShortcut` (facts table). iPad shows them to hardware keyboard users (discoverability overlay is not verified here: [INFERENCE]).
- **Mac adds menu-bar commands** through `.commands { CommandMenu("Conversation") { ... } }` on the `WindowGroup`'s scene, holding the same six actions with their shortcuts, enabled and disabled by the same state as the on-screen controls (Interrupt disabled with no active reply; Mute title toggles to Unmute). This is the Mac's visible, discoverable path and the iPad's omitted one.
- **Android** uses Ctrl-based equivalents because that is the platform's hardware-keyboard convention [INFERENCE]; it has no menu bar, so the shortcuts are exposed through Android's keyboard shortcuts helper and the content descriptions [INFERENCE: not built; Android owner to confirm].
- Shortcuts act only in the large layout and in compact with a hardware keyboard (F7 criterion 4); no shortcut is required for any action to be possible.

## 7. Platform differences (the only ones)

| Item | iPad / Mac | Android | Reason |
|---|---|---|---|
| Sidebar default | Visible when there is room; user toggles | Collapsed at Medium, visible at Expanded | Android canonical list-detail shows one pane at Medium (docs above). |
| Menu-bar commands | Mac only: `CommandMenu` | None | Android has no menu bar. |
| Shortcut modifiers | ⌘ family | Ctrl family | Platform keyboard convention [INFERENCE]. |
| Window class source | Resolver: iOS reads `horizontalSizeClass`; macOS always large | Resolver reads `WindowSizeClass` | Shared spec. |
| Back | Sidebar overlay dismisses on tap outside | System Back dismisses the overlay drawer | Platform convention [INFERENCE]. |
| Foldables | n/a | Follow the window width only; no fold-posture rule in this proposal | Docs: window size class changes on fold/unfold; owner may add posture rules later. |

## 8. Impact on large-format criteria of FB-THINK, FB-TYPE, FB-MUTE

If the owner approves this proposal as written:

- **F6 (thinking text).** Criterion 4's "pane or panel placed by FB-LAYOUT" becomes the thinking pane in the side panel, in place (no sheet) on large. Tapping a Thinking row selects that turn in the pane and opens the pane if hidden; the row stays in the transcript (criterion 3) and remains the only entry point. The pane accumulates live, does not auto-scroll once the user scrolled up, and closing it (⌥⌘T or the toggle) returns to the same transcript position. Reduce Motion: no animated expansion (criterion 7). Platform note: macOS identical to iPad.
- **F7 (typing view).** Criterion 10 is satisfied by this arrangement: transcript and composer always visible, small orb in the voice cluster, optional sidebar. Criterion 4's "one keyboard shortcut" = ⌘⇧L (Ctrl+Shift+L on Android) and, on the Mac, the Conversation menu item. Criterion 2's transition on large changes only focus (composer), not layout, in the recommended arrangement; in the alternative arrangement the large orb shrinks as on compact.
- **F8 (mute).** Criterion 11 is satisfied: Mute sits with the small orb, between orb and Interrupt, distinct glyph (speaker, slashed when muted) and label from Interrupt (square stop). Criterion 7's "Muted" appears in the status line header.
- **Until approval**, F6, F7 and F8 large windows use the compact behaviour (their own wording), so F9 is not a blocker for their compact scope.

## 9. Open decisions for the owner

1. Approve this proposal (criterion 6) or request changes; record the approval date in the spec.
2. Choose: one arrangement with always-small orb (recommended) or the alternative (large orb in voice view).
3. Approve or change the shortcut set (all six are proposals; F7 builds ⌘⇧L provisionally).
4. Android owner review of section 7 and the Android shortcuts; the Android notes rest on documentation and the twin spec, not on a build.
5. Side panel width and whether the thinking pane may be resized or only toggled [INFERENCE: not decided here].
6. Whether the voice cluster should also appear in the Mac toolbar (extra Mac-only placement); not proposed.

Dependency note: `story-index.yaml` lists F9 as a dependency of F6-F8 and F5 for F8 and omits F7 for F6; that file is left unedited by this PR. F6-F8 compact scope proceeds without F9 approval.

## 10. Approval

| Field | Value |
|---|---|
| Status | proposed; owner approval required |
| Owner decision | pending |
| Arrangement chosen | pending |
| Shortcuts approved | pending |
| Android owner review | pending |
| Approval date | pending |

## 11. [INFERENCE] items (not verified)

- Sidebar, side panel and pane widths; the inspector's compact-class behaviour; the sidebar/pane visibility being a width-driven sub-choice inside the large layout.
- Android: `SupportingPaneScaffold` and a drawer/rail fit this layout (not built); Ctrl-based convention, shortcut collisions (Ctrl+L, Ctrl+Alt+T), shortcut helper exposure, Back behaviour for the overlay drawer.
- Apple: ⌘. as cancel convention; iPad hardware-keyboard shortcut overlay; no conflict check of ⌘⇧M and ⌥⌘T with system shortcuts.
- Material 3 guidance beyond the pages quoted above was not read in full.
