---
title: 'IOS-UX-F6 — Make Hermes's thinking text readable'
type: 'experiment'
created: '2026-10-07'
status: 'in-review'
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

## Open Questions

PROVISIONAL decisions: the owner has not confirmed these. Work proceeds on them under the director's authorization; the owner corrects afterwards.

- Dependency on `IOS-UX-F9` — options: ignore F9 for compact work; iPad and Mac open the compact sheet until F9 is approved, so no pane and no layout-class resolver is built here / wait for F9. **Provisional: ignore F9.** `story-index.yaml` lists `ios:IOS-UX-F9` as the only dependency, and does not list `IOS-UX-F7` although this work sits in F7's transcript; the index is left unedited and the mismatch is recorded here. This branch is stacked on F7 (and F8).
- Which surfaces carry the row — options: the typing-view transcript (F7), the history sheet, and the voice rail's latest turn / typing view and history only (the voice view then shows thinking only as the orb state "Thinking"). **Provisional: all three**, so removing the bottom-bar line leaves no view without a thinking cue.
- When a row exists — options: only when thinking text arrived for the turn / also for a status-only "thinking" phase (Home activity enum, no text). **Provisional: only when text arrived.** Status-only phases keep the bottom-bar status line.
- Reasoning on the completed message may repeat what deltas already delivered — options: on completion, add it only when it is not already contained in the accumulated text / always append. **Provisional: add only when not contained**; deltas always append (TUI `gateway_session.py:882` treats `reasoning.available` text as one more delta).
- Experiment outcome (keep, change or remove) is the owner's after use; this PR does not close it.

## Code Map

Verified against `origin/main` e58974f (the earlier draft's line numbers had drifted).

- `HermesRelay/ViewModels/ConversationStore.swift` -- `apply(_:)` `:3070`: `.thinkingDelta` `:3098` and `.status` `:3100` both write `activityText` (declared `:107`, also set by Home activity at `:1824` and cleared at turn start `:2077`, `:2189`, completion `:3117`); `.messageComplete(_, _, failureReason)` `:3111` drops `reasoning`; `.turnInterrupted` `:3106`. Turn starts at `:2075` (Standard) and `:2187` (Home); `messages = []` on profile clear `:2809`; restore sets `messages` at `:239`. Add here: an in-memory `thinkingTurns` beside `messages`, never in `PersistedConversation` (`persistConversation` `:3131`).
- `HermesRelay/Models/SessionModels.swift` -- `TranscriptMessage` `:294` is `Codable` and persisted: do not add thinking to it. `HermesEvent.messageComplete(text:reasoning:failureReason:)` carries the reasoning.
- `HermesRelay/Services/HermesEventNormalizer.swift` -- `:74-78` and `:194-197` map thinking and reasoning events to `.thinkingDelta(text)`; no change needed.
- `HermesRelay/Views/ContentView.swift` -- `:487-496` bottom-bar `ProgressView` plus one `.lineLimit(1)` line: the thinking path through it is removed, status stays. Sheet host: add a `.sheet(item:)` beside the existing sheets (`:330-365`).
- `HermesRelay/Views/AmbientHUD.swift` -- `TranscriptHistoryView` `:1140`; F7's `TypingTranscriptView`; `RecentTranscriptRail.swift` projection `:25` and display `:426` for the voice view. `MessageBubble.swift` is the row pattern.
- Tests: `HermesRelayTests/ConversationStoreTransportTests.swift`, `HermesRelayTests/ConversationPersistenceTests.swift`, `HermesRelayTests/HermesRelayTests.swift`; some existing tests assert thinking text in `activityText` and change with this slice.

## Boundaries

- No Hermes protocol, Home or wire change. Content-safe diagnostics only.
- Large-format criteria depend on `IOS-UX-F9` (FB-LAYOUT) approval; compact criteria are buildable now.
- macOS: a Mac window is large; the opened thinking view is the FB-LAYOUT pane, identical to iPad.
- The row replaces `ContentView.swift:487-496`; accumulated text lives beside `messages` in `ConversationStore`, not in `TranscriptMessage` persistence.

## Tasks & Acceptance

**Execution:**
- [ ] `ConversationStore.swift` -- `ThinkingTurn` (id, anchor message id, text, `isActive`) and `thinkingTurns`; append each thinking event to the current turn's text in arrival order; add completion reasoning by the containment rule; stop writing thinking to `activityText`; mark the turn inactive on completion, interruption or failure; clear on profile clear and conversation switch -- criteria 1, 2, 5
- [ ] `Views/ThinkingRow.swift` (new) -- fixed-height collapsed row ("Hermes is thinking" with spinner, "Hermes thought" when done), button trait, hint "Opens the thinking text" -- criteria 3, 6
- [ ] `Views/ThinkingSheet.swift` (new) -- full-screen sheet reading the live turn; follows new text only while the user is at the bottom; no animated scroll under Reduce Motion; text split by paragraph for line-by-line reading -- criteria 4, 6, 7
- [ ] `TypingTranscriptView.swift`, `TranscriptHistoryView`, `RecentTranscriptRail.swift` -- place the row after the turn's user message and before its reply, via one pure ordering helper -- criterion 3
- [ ] `ContentView.swift` -- remove the thinking line from the bottom bar; present the sheet; post one VoiceOver announcement "Hermes is thinking" when a new row appears, never per delta -- criteria 3, 6
- [ ] Tests listed in Verification; update tests that asserted thinking in `activityText`
- [ ] `spec-ios-ux-f6-thinking-text.md`, `sprint-status.yaml` -- record outcome (experiment stays open for owner review), move status to review

**Acceptance Criteria (compact; large uses the compact sheet until F9):**
- Given thinking events `a`, `b`, `c` for a turn, then the turn's text is `abc` in order and no later event replaces earlier text.
- Given a status update during thinking, then `activityText` changes and the thinking text is unchanged; thinking never appears in a reply message.
- Given completion-only reasoning, then a row exists with that text.
- Given a stored conversation is saved and reloaded, then no thinking text is in the file and no rows show for past turns.
- Given a turn with thinking, then exactly one collapsed fixed-height row shows before that turn's reply and keeps its place when the reply arrives; tapping opens the sheet, which grows live and returns to the same transcript position when closed.
- Given Reduce Motion, then neither the row nor the sheet scrolls or expands with animation.
- Given any thinking text, then it appears in no journal line, diagnostic or log.

## Implementation Notes

Implemented 2026-10-10 on `feat/ios-ux-f6-thinking-text` (stacked on F7 and F8), compact scope only. EXPERIMENT: the owner decides keep, change or remove after use.

- `ConversationStore`: `ThinkingTurn` / `thinkingTurns` beside `messages`, in memory only. `.thinkingDelta` appends to the active turn (anchored to the newest user message); `.status` still goes to `activityText` only; `.messageComplete` reasoning is added when not already contained. The turn ends on completion, interruption, failure and the next turn; cleared on restore and profile clear. Nothing is added to `TranscriptMessage`, `PersistedConversation`, `TranscriptExport` or the journal.
- `ThinkingRow` (fixed 40 pt, "Hermes is thinking" / "Hermes thought", label never carries the text) and `ThinkingSheet` (live, follows only while at the bottom via `onScrollGeometryChange`, no animated scroll under Reduce Motion, one element per paragraph). `ThinkingTranscriptOrdering` places each row after its user message; shown in the typing transcript, the history sheet (own nested sheet) and above the voice rail for the latest exchange.
- `ContentView`: sheet presentation and one VoiceOver announcement "Hermes is thinking" when a row is added. The bottom-bar status line stays for status text; thinking no longer feeds it.
- Home activity `thinking`/`reasoning` without text still shows as the status line (no row).

## Verification record

- iOS Simulator: 694 tests, 0 failures (baseline 667; F8 +14, F7 +6, F6 +7). macOS: 693 tests, 0 failures (baseline 666). No reruns needed.
- New tests assert append order, status separation, completion reasoning (shown once, not duplicated), one turn per turn, row ordering, follow rule, and that thinking text is absent from the stored conversation file, exports and the diagnostics journal and that a relaunch shows no rows.

## Experiment record

Owner review after use (keep, change, remove): pending.

## Spec Change Log

## Review Triage Log

## Design Notes

- Keying: a turn is anchored to the user message that began it, so the row renders between that message and the reply even though the reply message does not exist yet while thinking.
- Thinking never reaches `TranscriptMessage`, `PersistedConversation`, `TranscriptExport` or the journal.
- Follow rule: reuse the shape of `RecentTranscriptFollowState` (`RecentTranscriptRail.swift:83`) for the sheet.

## Verification

**Commands:**
- `xcodebuild … test` (iOS Simulator, CI command) -- expected: all pass, baseline 667 plus F8's, F7's and new.
- `xcodebuild … -destination 'platform=macOS' test` -- expected: all pass, baseline 666 plus F8's, F7's and new.

**Tests:** deltas append in order; status never overwrites thinking; completion-only reasoning shown and not duplicated; interrupted and failed turns end the row; nothing persisted (save then load); cleared on profile clear; the ordering helper puts the row after its user message and before the reply; follow state stops following when the user scrolls up.

**Pending device:** a long-thinking turn on iPhone (row stays still, sheet grows live, closing keeps position); VoiceOver (one announcement, text readable when opened); Reduce Motion; iPad and Mac open the compact sheet.
