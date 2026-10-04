---
id: IOS-HOME-03
title: Keep Home conversations resumable, stop leaking claims, and let people close open ones
status: in-progress
baseline_commit: db398722abbb6532e2375e614c4a026e93f10a7d
depends_on:
  - home:HOME-NW-17
  - home:HOME-NW-18 (slice C only)
---

# IOS-HOME-03 — Home claim lifecycle

## Why

Live pilot evidence from 2026-09-27 (UTC), app 0.5.0, Release builds:

- **Local reconnect refusal (iPhone18,1, Profile `jensen`).** A connection dropped mid-reply at 01:02:45. At 01:02:52 Home answered `conversation.open` with `reconnect_required`. Two milliseconds later the app reported `reconnect result=unavailable code=conversation_mismatch phase=reconnect`, without sending `conversation.reconnect`. The reply was lost, and the next connect made a new conversation. `HomeBridgeSessionClient.reconnect` refuses a binding unless it is `==` to the client's `currentBinding`, which includes `capabilities`. `ConversationStore` deliberately compares identity only (`isSameConversation`: Profile, handle, endpoint, route, household). The client-side refusal records no journal line, so the export can't name the differing field.
- **Claim leak (iPad14,5, shared Profile `spark`).** Between 01:07:56 and 01:08:15, seven client claims were created on Home and never opened: `activity: ready`, no Session, each expiring 90 s later. With the existing conversation they filled the device's limit of 8, and the next connect was refused with `claim_limit` ("too many open Home conversations"). The iPad's own export shows the cause. At 01:07:51 its reconnect was refused locally, as on the iPhone. Every connect after that made a new claim, and `HomeBridgeSessionClient.open` then refused it locally with `conversation_mismatch phase=open`, because the client still held the old conversation's binding with no live bridge. There were seven such refusals between 01:07:56 and 01:08:15, one per leaked claim, and they continued until 01:11. Home keeps a claim until its deadline, and the client has no way to see or release a claim it has lost track of.

## Scope

### A — Resume uses conversation identity, and says why when it refuses (no Home dependency)

- `HomeBridgeSessionClient` checks a caller's binding on reconnect, close and turn operations with the same identity rule as `ConversationStore.isSameConversation`. Capabilities are refreshed from Home's `ready` result, never used as identity.
- Every client-side refusal records `home connect local mismatch site=<site> fields=<names>` in the diagnostics journal. Field names only, never values.

### B — Never abandon a claim without releasing it (no Home dependency for the guard)

- Starting or switching a conversation, or disconnecting while a claim is held but not yet open, releases it by explicit `claim_ref` when one was returned. A response lost during claim creation cannot be recovered by any route; that outcome stays ambiguous and is never retried automatically.
- Connect attempts are serialized: a second connect while one is in progress joins it, never making a parallel claim. A claim response arriving after disconnect/profile change is released by its explicit ref instead of being adopted by the stale operation.
- Claim creation/release diagnostics record fixed lifecycle events without handles or refs. References remain memory-only.

### C — "Open on Home": see and close this device's open conversations (needs HOME-NW-18)

- The Conversations sheet shows "Open on Home (N open · max M)" using Home's `max_claims`, not a hard-coded limit. Each claim shows its Profile label, best-effort title, opened time (`opened_at`, falling back to `created_at`), and state (connecting, idle, replying, waiting to reconnect). The current claim is marked.
- Titles are an optional enrichment from `client-sessions/list`, matched by both `grant_id` and `session_ref`; missing titles never block listing or closing. The Close action excludes the current claim; **Close all others** submits only explicit refs for every other listed claim. Re-list after success or any timeout/error before deciding what remains open; `not_open` is a safe no-op.
- Feature detection starts only after a successful create response includes `claim_ref`. Legacy responses without a ref and a `404 not_found` from the HOME-NW-18 list/close routes keep this UI hidden. When detected, **Manage open conversations** opens this section directly after `claim_limit`.
- Closing never deletes the Hermes session: it stays in the conversation list and can be resumed. A confirmed `closed` result means Home closed that claim with reason `client_closed`.

## Acceptance

- **A (fake clients):** open a conversation, drop the transport mid-turn, have the fake Home answer `reconnect_required` with capabilities that differ from the original `ready`. The app sends `conversation.reconnect`, resumes the same conversation, and records no mismatch.
- **A (fake clients):** a reconnect with a genuinely different handle is refused locally, and the journal line names `conversationHandle` and no values.
- **B (fake clients):** rapid repeated connects while the fake claim provider is slow produce one claim, not parallel claims. A claim response that arrives after disconnect is explicitly closed when its ref is available; a claim-creation response lost before delivery is never automatically retried.
- **C (fake Home service):** the list shows the device's claims with the current one marked and the server-reported limit. Tests cover `opened_at: null`, missing best-effort titles, and a count above `max_claims`; Close and Close all others submit only non-current refs and re-list after success or failure. A legacy `404 not_found` hides the section.
- **C (stale async responses):** A delayed nil list/close response after a newer profile load cannot clear its current claim list, and late title support cannot overwrite titles for a newer list.
- No handles, `claim_ref` values, Session IDs, prompts or replies appear in logs or the diagnostics journal.
- **macOS Settings regression (reported 2026-10-03; source screenshot: `/Users/amandachappell/Library/Application Support/CleanShot/media/media_sUeECtrubQ/CleanShot 2026-10-03 at 11.03.13 PM@2x.png`):** At constrained window sizes, the grouped Settings form stays scrollable within the host sheet; all labels/help text remain fully visible, and flexible sheet sizing never exceeds the host window.
- macOS build and XCTest pass, and a generic iOS Simulator build compiles. Simulator test execution remains gated on an installed runtime/device; the physical-device pilot check is still outstanding.

## Progress

- **Slice A — done on `fix/ios-home-claim-lifecycle`, not yet released.**
  - `HomeConversationBinding.isSameConversation(as:)` is now the single identity rule, shared by the client and the store.
  - `reconnect` keeps the client's established capabilities for the same conversation.
  - `open` drops a held binding that is no longer live instead of refusing every fresh claim; a live conversation still refuses.
  - Client-side refusals record `home connect local mismatch site=… fields=…` in the diagnostics journal.
  - Regression tests in `HomeBridgeSessionClientTests`: the two pilot-reproducing tests fail on the previous code and pass now. Full iOS suite: 543 tests pass. The macOS build succeeds.
- **Slices B/C:** implementation and final local integration checks complete; iOS Simulator runtime/device and real-pilot gates remain outstanding.
  - Post-review Xcode 27.2 Beta 2 macOS XCTest/build passed: 562 tests, 0 failures. Generic iOS Simulator 27.2 compile succeeded for arm64 and x86_64; compile-only because no simulator runtime/device was installed. Exact commands, result bundles, UI evidence, and limits are in [validation-ios-home-03.md](validation-ios-home-03.md).
  - Compatibility fix: deployed Home `082e593` returns `claim_ref` on successful claim creation. The prior iOS strict decoder rejected that field, so paired claim creation would fail as an invalid response. The model now decodes the optional ref and still accepts legacy responses without one.
  - Actual macOS UI smoke with `-HomeBridgeFake` and a fresh `CFFIXED_USER_HOME` displayed the synthetic current/other claims and Home limit. **Close** and **Close all others** each removed only the synthetic non-current claim. Evidence: `/tmp/ios-home03-ui-smoke-final-manager-20261003.png`, `/tmp/ios-home03-ui-smoke-final-close-20261003.png`, `/tmp/ios-home03-ui-smoke-single-close-20261003.png`. No Home or deployment requests, real prompts, or user app-support writes were used.
  - Actual macOS Settings smoke after the layout fix: normal host 708×762 and compact host 620×480; wrapped help and labels stayed readable, footer actions were reachable, and Done remained fixed. Clicking Done after scrolling dismissed the sheet (Accessibility sheet count 0). Screenshots: `/tmp/ios-settings-layout-normal-top.png`, `/tmp/ios-settings-layout-normal-bottom.png`, `/tmp/ios-settings-layout-small-top.png`, `/tmp/ios-settings-layout-small-bottom.png`, `/tmp/ios-settings-layout-small-fields.png`.
  - iOS simulator tests were not run: no simulator runtime/device was installed, and no runtime download was attempted. No physical-device pilot or live household claim operation was performed.

## Review Triage Log

- **Blind Hunter — medium / patch (fixed):** The original `ambiguousClaimCreationProfiles` set permanently blocked subsequent `makePairedHomeClaim` attempts after a lost create response, although Home expires unopened claims within 90 seconds and the UI asks users to connect again after expiry. The guard now uses a monotonic 90-second retry deadline: immediate repeats remain blocked, but a subsequent connect after expiry can proceed. `testLostClaimResponseIsNotAutomaticallyRetried` passed after the fix.
