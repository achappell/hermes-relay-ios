---
title: 'Configure and expose deterministic single-Device wake arbitration (3-I-4)'
type: feature
created: '2026-09-12'
status: 'in_progress'
route: 'architecture'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-validate-unique-wake-mappings-and-profile-specific-publish-state.md'
  - '{project-root}/docs/architecture.md'
---

<frozen-after-approval reason="human-owned intent recorded during the 2026-09-12 architecture walkthrough">

## Intent

**Problem:** Multiple wake-capable Devices may hear the same household wake
trigger. Without a shared canonical configuration and one arbitration authority,
more than one Device can acknowledge, capture, or submit the same turn.

**Approach:** Use one local Home service with two internal roles: a durable
canonical configuration store and a low-latency wake-arbitration engine. iOS and
Android administer the household configuration through a versioned JSON/HTTP
API. ESP32 Touch, web Hands-Free Home, and iPad Hands-Free Home may all submit
the same authenticated pre-capture WakeClaim. The Home service selects one
eligible claimant; only that Device captures.

## Boundaries & Constraints

**Always:** The Home service owns canonical household configuration, monotonic
configuration revisions, canonical Wake Mapping IDs, Device Rooms, wake
capabilities, and unique per-Room priority ranks. Configuration publishes are
whole-household snapshots guarded by the expected revision and activated
atomically. A WakeClaim contains a unique claim ID, authenticated Device ID,
canonical wake-trigger ID, observation metadata, and acoustic proximity
evidence. A first valid claim opens a 250 ms arbitration window; the strongest
eligible acoustic evidence wins and priority rank resolves an effective tie.
The selected Device receives a grant and uploads using the same claim ID.

**Never:** Do not use Wi-Fi RSSI as physical proximity, send Profile IDs,
wake phrases, prompts, transcripts, or audio in a WakeClaim, let a Device pick
its own Profile or winner, accept stale configuration revisions, promote a
partial publish, or retry a failed winner by promoting a loser from the same
wake event. Unknown, revoked, unavailable, stale, malformed, or expired claims
fail closed. The iOS app does not arbitrate live wake events; it administers
and presents the canonical configuration and may itself be a wake claimant
when running Hands-Free Home.

## Acceptance Criteria

- Given a household configuration, when iOS reads or publishes it through the
  Home-service seam, then the configuration includes a server-owned revision,
  canonical wake-trigger IDs, per-Device Profile assignments, Rooms, and
  unique positive per-Room priority ranks.
- Given an iOS edit based on an old revision, when another client has already
  published a newer snapshot, then the Home service rejects the stale write and
  iOS retains the verified configuration rather than overwriting newer state.
- Given a mapping assigned to multiple wake-capable Devices, when the Devices
  claim the same wake trigger, then the bridge groups them by canonical mapping
  ID, chooses one eligible winner after the bounded arbitration window, and
  returns a grant or denial tied to each claim ID.
- Given a denied, missing, expired, revoked, unavailable, malformed, or late
  claim, when a Device would otherwise begin capture, then it remains silent and
  submits no audio or Hermes turn.
- Given a granted winner that fails before upload, when the event is settled,
  then no loser is promoted and a new wake is required for another attempt.
- Given the iOS app is used as a Hands-Free Home claimant, when its local wake
  detector fires, then it participates through the same claim/grant contract as
  ESP32 Touch and web claimants; iOS does not become a second arbitration
  authority.
- Given the macOS target is built, when this slice is present, then existing
  conversation and relay-profile behavior remains unchanged.

## Decisions

- The canonical mapping ID identifies the household wake trigger. Profile
  assignment is stored per Device, so the winning Device resolves its own
  configured Hermes Profile after arbitration.
- The bridge orders claims using its monotonic receive clock, not untrusted
  Device wall-clock timestamps.
- Priority is a Device setting, not a mapping setting; rank `1` is highest and
  duplicate ranks within a Room are invalid.
- The first iOS implementation extends typed models and client seams. The
  production Home-service transport, Device credential handshake, and exact
  acoustic evidence encoding remain cross-surface dependencies until their
  shared contract is published.

## Code Map

- `HermesRelay/Models/DeviceModels.swift` — canonical mapping references,
  arbitration priority, Home configuration snapshots, and revision semantics.
- `HermesRelay/Services/DeviceDiscoveryClient.swift` — typed Home-service
  configuration seam; no guessed production wire implementation.
- `HermesRelayTests/DeviceDiscoveryTests.swift` — canonical-ID and snapshot
  validation coverage.

The existing per-Device setup editor remains a separate local projection until
the Home service contract supplies household mappings and cross-Device
priority validation. It is not promoted to the new canonical path by this
foundation slice.

## Open Questions

- Exact acoustic evidence representation, normalization, calibration, and
  effective tie band require the wake-capable hardware contract.
- Device-scoped credential issuance, revocation propagation, and the Home
  service authentication handshake require the shared Device contract.
- Live configuration update notifications can be added after the versioned
  HTTP read/write path is proven; polling is sufficient for the first seam.

## Verification

Implementation foundation verified:

- Focused `DeviceDiscoveryTests`: 72 passed, 0 failed, 0 skipped on the iPhone
  17 Pro / iOS 26.5 simulator.
- Full iOS Simulator suite: 325 passed, 0 failed, 0 skipped.
- iOS Simulator test build: succeeded.
- macOS Debug build: succeeded.
- `git diff --check`: clean.

The production Home-service HTTP client, live arbitration engine, device
credential handshake, and hardware/manual smoke evidence remain open; this
slice intentionally supplies only the iOS model and typed seam for them.

</frozen-after-approval>
