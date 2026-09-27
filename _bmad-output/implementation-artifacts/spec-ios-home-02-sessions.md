---
title: 'IOS-HOME-02 (slice 2) — Manage Home client sessions on iOS and macOS'
type: 'feature'
created: '2026-09-26'
status: 'draft'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/course-correction-2026-09-23.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-02.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-02-pair-and-connect.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every connect makes a client claim with `session: {"mode": "new"}`, so each launch, profile switch or return after Home's reconnect grace starts a fresh Hermes session. A conversation cannot be continued later, conversations started on a Puck, Touch panel or the TUI cannot be picked up on the phone, and the current session cannot be renamed. HOME-NW-17 already provides everything needed: a claim can name `new`, `most_recent` or `resume` with an opaque `session_ref`; `POST /api/v1/client-sessions/list` lists the Profile's sessions; `POST /api/v1/client-claims/session` names the session a claim is using; and renaming uses Hermes's advertised `title` command through `command.dispatch`.

**Approach:** Claim `most_recent` on connect. Add a Sessions sheet, opened from the profile header, that lists the Profile's sessions and offers New session, Resume and Rename current. Switching sessions closes the current claim and makes a new one, as a CLI reconnects; the bridge core is unchanged. Resuming keeps the local transcript and inserts a divider naming the session.

</frozen-after-approval>

## Decisions (2026-09-26, user)

1. **Default session on connect: most recent.** Connect claims `{"mode": "most_recent"}`; Home falls back to `new` when the Profile has no stored session. This applies to launch, Profile switch, and the fresh claim made after a claim is refused (for example after the reconnect grace).
2. **Placement: a sheet from the profile header.** Tapping the header card opens a Sessions sheet: the list (title, last active, message count, an "In use" badge for `active: true`), New session, Resume on a row, and Rename current.
3. **Transcript on resume: keep it, add a divider.** Resuming keeps the local transcript and inserts a local divider "Resumed: <title>". Hermes holds the full history and uses it for replies; Home has no API to return old messages, and none is invented.

## Boundaries & Constraints

- Unmodified Standard through Home only. Use exactly the HOME-NW-17 operations above; invent no other session operation (no delete, no message fetch, no server-side undo).
- `session_ref` values are opaque, grant-scoped, and held in memory only. Never persist a `session_ref`, Standard Session ID, Profile ID or handle; the existing no-secrets persistence test must keep passing.
- One claim, one session. A switch is: `conversation.close` on the current claim, then a new client claim naming the session, then `conversation.open`, reusing slice 1's connect path. Never switch while a turn is in flight or uncertain; the actions are disabled with a reason.
- Resume never replays. An uncertain turn stays reported and is never re-sent into another session.
- `session_busy` (another claim, such as a live Puck turn or another window, holds the session) and `session_unavailable` (unknown or foreign `session_ref`) are shown plainly, with no automatic retry. Both leave the current session untouched when the close has not yet happened; if the new claim is refused after the close, fall back to `most_recent` once and say so.
- Rename only when Hermes advertises `title` (bridge capabilities `commands`); otherwise hide Rename. A rename refreshes the list.
- A new session has no `session_ref` until its first accepted turn; the sheet shows it as the current, untitled session.
- List is bounded (Home: 1–50, default 50, newest first). No pagination in this slice.
- Content-safe diagnostics only (codes, counts, durations). No titles in logs.
- iOS and macOS share the implementation; the sheet must work with pointer and keyboard on macOS.
- Legacy operator-handle profiles are unchanged and show no Sessions sheet.

## I/O & Edge-Case Matrix

| Situation | Result |
| --- | --- |
| Launch or profile switch, Profile has sessions | Claim `most_recent`; lands in the latest session; header shows its title once known |
| Launch, Profile has no sessions | Home falls back to `new`; untitled current session |
| Open sheet | `client-sessions/list` fetched; current session marked; others resumable; `active` rows badged "In use" |
| List fails (network, `service_unavailable`) | Plain error in the sheet with Retry; current session unaffected |
| New session | Close current claim; claim `new`; open; divider "New session" |
| Resume a row | Close current claim; claim `resume` with its `session_ref`; open; divider "Resumed: <title>" |
| Resume a session in use elsewhere | Row badged; action shows `session_busy` explanation and does nothing |
| Resume returns `session_unavailable` | Plain message; list refreshed; fall back to `most_recent` once if the old claim was already closed |
| Turn in flight or uncertain | New/Resume disabled with "Finish or resolve the current turn first" |
| Rename current (title advertised) | `command.dispatch` `title <name>`; list refreshed; header title updated |
| Rename, title not advertised | Rename hidden |
| Rename on an untitled new session before its first turn | Rename disabled until the first accepted turn gives it a `session_ref` |
| Return from background within grace | Unchanged from slice 1 (reconnect same claim and session) |
| Return after grace | Fresh claim uses `most_recent`, landing back in the same session |
| Legacy operator profile | No sheet; unchanged |

## Code Map

- `HermesRelay/Services/HomeClientService.swift` — client-claim body accepts a session choice; add `listSessions` (`POST /api/v1/client-sessions/list`) and `claimSession` (`POST /api/v1/client-claims/session`) on the protocol, URLSession and fake implementations.
- `HermesRelay/Models/HomeClientPairingModels.swift` — session choice encoding (`new`, `most_recent`, `resume` + `session_ref`); decode the claim's `session` result and the list rows; keep refs out of `Codable` persistence types.
- `HermesRelay/ViewModels/ConversationStore.swift` — default `most_recent` in `makePairedHomeClaim`; a `switchHomeSession(to:)` that closes, claims and opens through the existing connect path; current-session state (ref, title) in memory; divider insertion; guards for in-flight or uncertain turns.
- `HermesRelay/Views/AmbientHUD.swift` — make `sessionHeader` open the sheet for paired Home profiles and show the current session title.
- New `HermesRelay/Views/HomeSessionsView.swift` — the sheet. The project uses explicit file references (no synchronized groups), so the new file needs `project.pbxproj` entries for both targets.
- `HermesRelayTests/` — service body and decoding tests, store switching tests with the fake client, and the no-secrets persistence test extended to session refs.

## Tasks & Acceptance

1. Session choice in the claim body and the claim/list/lookup responses, with contract tests against HOME-NW-17 examples.
2. Connect claims `most_recent`; fallback-to-new covered by tests.
3. Store switching (new, resume) with close-then-claim ordering, busy/unavailable handling, in-flight guards and dividers; tests with the fake client.
4. Rename via `title` when advertised; hidden otherwise; tests.
5. Sessions sheet UI on iOS and macOS; header entry point and current title.
6. Verification below, recorded in `validation-ios-home-02.md` under a slice-2 section.

Acceptance: a session started on one client (e.g. the TUI or a Puck) can be resumed on iOS and macOS; connect lands in the most recent session; New, Resume and Rename behave as in the matrix; no `session_ref`, Session ID, Profile ID or handle reaches disk or logs; an uncertain turn is never replayed.

## Verification

- Focused XCTest for the new service, model and store paths; full iOS Simulator suite; macOS build.
- Live, iOS and macOS separately: connect lands in most recent; list shows sessions from another client; resume one; New session; rename; `session_busy` against a session held by another claim; background beyond grace returns to the same session.

## Spec Change Log

- 2026-09-26: Drafted with the user's three decisions; awaiting readiness review.
