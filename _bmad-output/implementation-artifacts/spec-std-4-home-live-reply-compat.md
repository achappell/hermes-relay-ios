---
title: 'STD-4 — Accept the live Home bridge open and submit replies'
type: 'bugfix'
created: '2026-09-16'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The STD-4 live pilot handshake against the deployed Home bridge
(Home `main` at `eb95002`, route `caticornqueen-tailnet`) reached Home, which
authenticated the Device credential, resolved the grant, and opened a Standard
session — but the app rejected the reply and stayed on the legacy relay. The
iOS decoders are stricter than the replies the live Home adapter actually sends:

1. `conversation.open` `ready` always carries `unresolved_turn: false`, which
   `HomeReadyWireResult` rejects as an unknown key.
2. `capabilities` always carries `audio` (Bool), which `HomeWireCapabilities`
   rejects, and carries `heartbeat` only when Standard supplies it, while iOS
   requires it.
3. `prompt.submit` returns `{schema, conversation_handle, turn_id, status}` with
   no `correlation_id` (matching the pinned contract example) and a status of
   `submitted` or `accepted`; iOS requires `correlation_id` and only accepts
   `accepted`. The first live text turn would therefore also fail.

**Approach:** Accept exactly those live shapes while keeping strict rejection of
every other unknown field. `audio` becomes an optional capability and
`heartbeat` defaults to `false` when absent. On open, `unresolved_turn: false`
means no unresolved turn, and a truthy value or turn object means the caller
must reconnect (`reconnect_required`), never an automatic replay. A turn's
correlation ID becomes optional: when Home supplies none, the turn ID alone
scopes that turn's events and audio. Submission status `submitted` is treated
the same as `accepted`. Tests use fixtures shaped like the live Home reply.

</frozen-after-approval>

## Implementation Notes

- Evidence: the 2026-09-16 pilot activation reached Home, which recorded a
  durable Standard session on the grant, while the app stayed on the legacy
  relay. Home's shapes come from `hermes-relay-home` `endpoint.py`
  (`_status_payload`, `_turn_payload`) and `standard.py` (`_capabilities`).
- `HomeBridgeModels.swift`: `HomeWireCapabilities` gains optional `audio` and
  defaults an absent `heartbeat` to `false`; `HomeReadyWireResult` accepts
  `unresolved_turn` (absent/null/false → none; true/object → unresolved; any
  other type → `invalidShape`); `HomeTurnBinding.correlationID` is optional;
  new `homeCorrelationMatches(expected:received:)` compares correlation IDs
  only when both sides carry one.
- `HomeBridgeSessionClient.swift`: open returns `reconnectRequired` for an
  unresolved turn only after route identity and reason checks pass; submission
  accepts `submitted` or `accepted`, and an optional (but never empty)
  `correlation_id`; audio scope matching uses the shared helper.
- `ConversationStore.swift`: persisted and reconnect-restored turns keep their
  turn ID when the correlation ID is absent; sentinel correlation values are
  still used when no turn ID is known; live event matching uses the shared
  helper.
- Tests: `HomeBridgeSessionClientTests` adds a raw result override on the fake
  socket plus five tests covering the live open/submit replies, unresolved turn
  (including wrong-route precedence), still-rejected unknown capability and
  malformed `unresolved_turn`, empty correlation ID, and correlation matching.
- Verification: focused Home suites 41 passed; full iOS simulator suite 430
  passed; macOS arm64 build passed; `git diff --check` clean; no pilot route,
  handle, or credential values in the diff.
- Follow-up outside this repository: Home's
  `_bmad-output/specs/spec-home-bridge-route-roaming/bridge-contract.md` ready
  example omits `audio`, `interrupt`, and `unresolved_turn: false`.

## Review Triage Log

- Blind Hunter layer skipped (no subagent authorized); inline self-review of
  the diff was performed instead.
- medium — unresolved-turn check ran before route identity validation, so a
  wrong-route server could elicit `reconnectRequired` and reconnect does not
  re-check the server's route identity. Patched: check moved after the identity
  and reason guards; test asserts `identityMismatch` wins.
- low (rejected) — `ConversationStore` restore paths with a nil correlation ID
  have no dedicated store-level test; behavior reduces to turn-ID matching
  already covered by the helper test, and a store harness test is more than a
  simple correction.
- false — relaxing `heartbeat` could weaken liveness: `bridge.ping` is never
  gated on the flag (contract), and absent heartbeat already mapped to `false`
  in `HomeBridgeCapabilities`' default.

