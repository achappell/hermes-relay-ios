---
title: 'Connect iOS Device administration to the local Home service (3-I-4)'
type: 'feature'
created: '2026-09-12'
status: 'draft'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-4-select-one-device-for-simultaneous-wake.md'
  - '{project-root}/docs/architecture.md'
  - 'hermes-relay-tui/_bmad-output/implementation-artifacts/spec-3-4-select-one-device-for-simultaneous-wake.md'
---

<frozen-after-approval reason="human-owned intent for the concrete iOS Home-service client slice">

## Intent

**Problem:** iOS now validates canonical wake mappings, per-Room priorities,
and revisioned household snapshots, but its Home-service seam is still an
unavailable stub. Device administration cannot yet read the canonical state or
publish a safe household edit.

**Approach:** Add a concrete URLSession-backed Home-service client and connect
it to the existing Device administration flow. Fetches decode and validate a
complete snapshot; publishes use the expected revision and preserve the last
verified state when the service rejects a stale edit. Live wake arbitration
remains owned by the Home service and is not implemented in iOS.

## Boundaries & Constraints

**Always:** Keep the Home service authoritative; use server-owned revisions and
canonical mapping IDs; validate the complete response before exposing it to the
UI; keep relay Profile tokens, prompts, transcripts, and audio out of Home
service requests; make transport and authorization failures explicit; keep
local Device row UUIDs as editor-only identity.

**Never:** Put a bearer token in source, logs, URLs, or snapshots; reuse the
Hermes relay token as an undocumented Home-service credential; overwrite a
verified local configuration after a stale-write response; implement the live
WakeClaim arbiter in the iOS process; or make macOS depend on iOS-only Device
administration UI.

**Approved authentication:** For the private single-household pilot, iOS uses
a dedicated Home-service admin bearer credential stored in Keychain. It is
sent only in an `Authorization` header and is distinct from both the Hermes
relay token and per-Device wake credentials. The credential may later migrate
to paired or certificate-backed authentication when the enrollment and
rotation system exists.

**Approved HTTP envelope:** The first Home-service contract uses versioned JSON
routes. A publish request carries `expected_revision` in its JSON body, and a
stale revision returns a typed conflict. HTTP `If-Match`/ETag semantics are
deferred until the service needs broader cache-validation behavior.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|-----------------------------|----------------|
| HAPPY_PATH_FETCH | Home service returns a complete valid snapshot | Client returns the validated `HomeConfigurationSnapshot` | N/A |
| HAPPY_PATH_PUBLISH | Valid snapshot plus matching expected revision | Client returns the newly authoritative snapshot and its revision | N/A |
| STALE_PUBLISH | Service rejects an old expected revision | Local verified state remains unchanged; UI asks the administrator to reload | Typed revision-conflict error |
| INVALID_RESPONSE | Service returns malformed or semantically invalid JSON | No partial state reaches the model | Typed unexpected-response error |
| UNAUTHORIZED | Service rejects the configured Home credential | No configuration is changed | Typed authorization error with credential recovery guidance |
| TRANSPORT_FAILURE | LAN service is unavailable or request times out | Existing verified state remains visible | Typed unavailable error with retry |

</frozen-after-approval>

## Code Map

- `HermesRelay/Services/DeviceDiscoveryClient.swift` -- existing
  `HomeServiceClient`, `HomeServiceError`, and unavailable implementation; add
  the concrete URLSession adapter and status/error mapping here to avoid a
  second service abstraction.
- `HermesRelay/Models/DeviceModels.swift` -- existing Codable snapshot,
  canonical mapping, revision, and semantic validation types; reuse them as
  the response/domain model and do not duplicate wire state elsewhere.
- `HermesRelay/Services/RelayConfigurationStore.swift` and
  `HermesRelay/Services/SecureValueStore.swift` -- existing actor-backed
  persistence and Keychain boundary; use a distinct Home-service credential
  account if the approved auth decision requires one.
- `HermesRelay/ViewModels/DeviceDiscoveryModel.swift` -- existing
  main-actor Device administration state machine; add Home snapshot loading,
  publish conflict handling, and retry without disturbing discovery or
  verified/pending Device setup semantics.
- `HermesRelay/Views/DeviceDiscoveryView.swift` -- existing iOS Device
  administration sheet; add the smallest visible canonical-configuration
  status/reload/publish affordance and preserve the inert-unconfigured flow.
- `HermesRelay/Views/ContentView.swift` and
  `HermesRelay/Views/RelayConfigurationView.swift` -- existing dependency
  injection path; keep Home service optional and unavailable by default until
  runtime configuration is supplied.
- `HermesRelayTests/DeviceDiscoveryTests.swift` -- deterministic fake-client
  coverage for valid fetch/publish, stale revision, invalid response,
  authorization, transport failure, and verified-state preservation.

## Tasks & Acceptance

**Execution:**
- [ ] `HermesRelay/Services/DeviceDiscoveryClient.swift` -- implement the
  approved versioned JSON/HTTP adapter, request construction, response
  validation, timeout, and typed status mapping.
- [ ] `HermesRelay/Services/RelayConfigurationStore.swift` -- persist the
  dedicated Home-service credential through the existing Keychain boundary if
  the approved authentication decision requires it.
- [ ] `HermesRelay/ViewModels/DeviceDiscoveryModel.swift` and
  `HermesRelay/Views/DeviceDiscoveryView.swift` -- connect canonical snapshot
  load/publish state to Device administration with safe conflict and retry
  presentation.
- [ ] `HermesRelayTests/DeviceDiscoveryTests.swift` -- exercise every matrix
  case with deterministic URL loading or injected request transport.

**Acceptance Criteria:**
- Given a valid Home-service response, when iOS loads household configuration,
  then it exposes only the fully decoded and validated canonical snapshot.
- Given a valid edit based on the current revision, when iOS publishes it,
  then the returned authoritative revision becomes the local verified basis.
- Given a stale revision response, when publish fails, then iOS preserves the
  last verified state, retains the attempted edit as pending, and presents a
  reload/retry path without overwriting newer household data.
- Given malformed, unauthorized, unavailable, or invalid service responses,
  when iOS handles them, then it makes no partial configuration active and
  presents a typed actionable failure.
- Given the macOS target is built, when this slice is present, then existing
  conversation, relay Profile, and Keychain behavior remains unchanged.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

The adapter should return domain snapshots rather than leaking HTTP response
types into `DeviceDiscoveryModel`. The model owns presentation state and local
verified/pending preservation; the Home service owns revision authority. A
successful publish is therefore a two-part event: the service response is
validated first, then local state is promoted.

## Verification

**Commands:**
- Focused `DeviceDiscoveryTests` on the iPhone 17 Pro / iOS 26.5 simulator --
  expected: all focused tests pass.
- Full iOS Simulator XCTest target -- expected: all tests pass.
- macOS Debug build -- expected: build succeeds with no iOS-only dependency.
- `git diff --check` -- expected: clean.

**Manual checks:**
- Open Manage household Devices with the Home client fixture, load a valid
  snapshot, publish a valid revision, and verify that a simulated conflict
  leaves the previous configuration active while exposing reload guidance.
