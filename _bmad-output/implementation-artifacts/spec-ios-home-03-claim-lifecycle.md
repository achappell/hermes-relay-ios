---
id: IOS-HOME-03
title: Keep Home conversations resumable, stop leaking claims, and let people close open ones
status: in-progress
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

- Starting or switching a conversation, or disconnecting, while a claim is held but not yet open must release that claim. Once HOME-NW-18 is deployed, the client releases it with `POST /api/v1/client-claims/close`. Until then, it at least doesn't create another claim while one is still connecting.
- Connect attempts are serialized: a second connect while one is in progress joins it, never making a parallel claim.
- The diagnostics journal records claim creation and release (`home claim created`, `home claim released reason=…`), without handles.

### C — "Open on Home": see and close this device's open conversations (needs HOME-NW-18)

- The Conversations sheet shows a section, "Open on Home (N of 8)". Each open claim for this device shows its Profile, conversation title if any, when it was opened, and its state (connecting, idle, replying, waiting to reconnect). The current conversation is marked.
- Each row other than the current one has a **Close** action. There's also **Close all others**. Closing calls `POST /api/v1/client-claims/close`, and the list refreshes afterwards.
- When a connect is refused with `claim_limit`, the error offers **Manage open conversations**, which opens that section directly, instead of only saying to wait.
- Closing never deletes the Hermes session: it stays in the conversation list and can be resumed.

## Acceptance

- **A (fake clients):** open a conversation, drop the transport mid-turn, have the fake Home answer `reconnect_required` with capabilities that differ from the original `ready`. The app sends `conversation.reconnect`, resumes the same conversation, and records no mismatch.
- **A (fake clients):** a reconnect with a genuinely different handle is refused locally, and the journal line names `conversationHandle` and no values.
- **B (fake clients):** tapping **Start new conversation** five times while the fake claim provider is slow produces one claim, not five. A claim that never opens is released on disconnect (once HOME-NW-18 is deployed) and is otherwise not repeated.
- **C (fake Home service):** the list shows the device's claims with the current one marked. Close and Close all others call the close route with the right `claim_ref`s and refresh. A `claim_limit` refusal offers Manage open conversations.
- No handles, `claim_ref` values, Session IDs, prompts or replies appear in logs or the diagnostics journal.
- iOS simulator tests and the macOS build pass. Pilot check: reproduce Jensen's mid-reply drop, and fill the limit on a test device and clear it from the app.

## Progress

- **Slice A — done on `fix/ios-home-claim-lifecycle`, not yet released.**
  - `HomeConversationBinding.isSameConversation(as:)` is now the single identity rule, shared by the client and the store.
  - `reconnect` keeps the client's established capabilities for the same conversation.
  - `open` drops a held binding that is no longer live instead of refusing every fresh claim; a live conversation still refuses.
  - Client-side refusals record `home connect local mismatch site=… fields=…` in the diagnostics journal.
  - Regression tests in `HomeBridgeSessionClientTests`: the two pilot-reproducing tests fail on the previous code and pass now. Full iOS suite: 543 tests pass. The macOS build succeeds.
- **Slice B:** the local refusal loop that leaked claims is fixed by slice A. Releasing unopened claims waits on HOME-NW-18, and connect serialization isn't started yet.
- **Slice C:** waiting on HOME-NW-18.
