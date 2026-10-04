---
id: IOS-DIAG-03
title: Receive and send Home connection-failure diagnostics handshake and request envelopes
status: review
product_epic: 6
depends_on:
  - home:HOME-NW-06
---

# IOS-DIAG-03 — Home connection-failure diagnostics correlation (client side)

The complete iOS/macOS side of HOME-NW-06: opt-in handshake, strict response decoding, per-socket `home_connection_id`, `prompt.submit` request stamping, correlated events, and schema-2 report emission with deterministic packing. Home implemented the server side in `hermes-relay-home` PR #71; the owner approved the shared contract on 2026-10-04 (canonical copy in the private product hub). Home code (`endpoint.py`, `client_reports.py`) is the wire authority.

Ownership: IOS-DIAG-02 (in review) delivers schema-1 automatic upload only; it does not own schema 2. Schema-2 events, origins and packing are therefore in scope here, as is the settings disclosure copy.

## Acceptance

### Decoder and capabilities (before the header is ever sent)

- The JSON-RPC response envelope allows a top-level `diagnostics` key. Only two exact shapes are accepted: ready `{version, home_connection_id}` and submit `{version, request_id, correlation_id}`, with integer `version` 1 (Booleans and strings rejected) and IDs matching `conn-`/`req-`/`corr-` + 32 lowercase hex. Anything else is dropped; diagnostics never fail the RPC. Notifications are unchanged.
- `HomeWireCapabilities` accepts `diagnostics_correlation_v1` (Bool) and `client_diagnostic_report_schemas` ([Int]) under its exact-key check. A malformed value decodes as absent instead of failing ready.
- The keys stay out of `HomeBridgeCapabilities`, so reconnect `capabilitiesMatch` and binding equality ignore them: gaining or losing diagnostics negotiation is never a conversation mismatch.

### Handshake and negotiation

- The bridge upgrade request sets `X-Hermes-Diagnostics-Version: 1` exactly once.
- `home_connection_id` is stored per socket from that socket's own ready (`conversation.open` or `conversation.reconnect`) before ready is returned. It is cleared on socket install, retire, transport loss and close.
- Negotiated means: `diagnostics_correlation_v1 == true`, `2 ∈ client_diagnostic_report_schemas`, and a valid ready `home_connection_id`.

### Request stamping and events

- On a negotiated socket each `prompt.submit` gets a fresh `req-` + 32 hex (128-bit random) and the top-level `diagnostics {version: 1, request_id}` — never inside `params`.
- Event names are only those Home's schema 2 accepts: the schema-1 names (`launch`, `active`, `inactive`, `background`, `connection_lost`, `connection_ready`, `connection_failed`, `request_started`, `request_completed`, `request_failed`) plus `client_response_received` and `client_request_resolved`.
- `request_started` is recorded before the frame is written, with `home_connection_id`, `request_id`, `leg: client_home`, `phase: submission`, `correlation_state: local_only`, `pending_state: awaiting_write`.
- A response whose diagnostics echo the same `request_id` records `client_response_received` (`correlation_id`, `response_kind` accepted/rejection by JSON-RPC result/error, `phase: response`). The client's final reading of that response records `client_request_resolved` (`response_kind` accepted only for an accepted submission). `request_completed`/`request_failed` carry the same IDs and the `correlation_id` when known.
- `correlation_state` stays `local_only` on the client: only Home decides `linked`/`ambiguous`, and only after the carrying socket closes (D1).
- Correlation IDs never enter the OS log or diagnostics journal.

### Schema-2 reports and packing

- Every stored event gets `event_id` (`evt-` + 32 hex) and a per-launch monotonic `sequence` once, at observation, and is never mutated. Context persisted before this story gets an identity once on load.
- Each launch's origin is fixed when first observed: current launch uses its app/build/OS versions with `provenance_status: unverified`; a version failing the regex is null and the status `unavailable`; launches with no recorded origin are all-null `unavailable`. Source revision and artifact digest are always null.
- The report schema is chosen per paired Home from its latest advertised `client_diagnostic_report_schemas` (2 only if advertised). Schema-1 reports keep their exact field set and omit schema-2 event names.
- Packing is deterministic: events in observation order are added greedily, with the origins they newly need, while the report stays ≤ 100 events and ≤ 65,536 body bytes; then it is sealed and the next opens. An event that cannot fit alone is dropped and counted. Each report carries only origins its events reference. Upload bytes are sorted-key compact JSON, so a retry resends identical bytes. Existing bounds (10 queued reports, 1/min, 7-day expiry) are unchanged.
- The receipt check remains `schema == 1` (D4).

### Legacy behavior

- Home without the capability, a non-opted-in socket, or no valid ready ID: no request `diagnostics`, the same request fields as before, schema-1 reports.

## Validation

- Unit tests with fake sockets: decoder strictness (ten malformed ready shapes, malformed submit echo), header exactly once, capability-gated negotiation (five partial/malformed capability sets), reconnect to legacy and to a new opted-in socket (no mismatch; new socket uses its own ID, old ID cleared), fresh unique request IDs, `request_started` present before the frame is written, correlated accepted and rejected responses, legacy frame unchanged.
- Reporter tests: schema-2 report field/origin/sequence shape, legacy schema-1 report, packing bounds/determinism/drop accounting/referenced origins, origin null rules.
- Device acceptance per the Home hand-off §3, including closing the carrying socket before checking `linked` (D1) and a legacy Home regression.

## Source references

- Home hand-off: `hermes-relay-home:_bmad-output/implementation-artifacts/ios-handoff-home-nw-06-diagnostics.md`
- Home validator: `hermes-relay-home:src/hermes_home/observability/client_reports.py`; injection/validation: `src/hermes_home/bridge/endpoint.py`
- Approved shared contract: product hub (private), 2026-10-04.
