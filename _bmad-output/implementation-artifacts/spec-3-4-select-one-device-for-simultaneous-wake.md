---
title: 'iOS delivery record: deterministic single-Device wake arbitration (3-I-4)'
type: feature
created: '2026-09-12'
status: 'in_progress'
route: 'delivery'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-validate-unique-wake-mappings-and-profile-specific-publish-state.md'
  - '{project-root}/docs/architecture.md'
  - 'hermes-relay-tui/_bmad-output/implementation-artifacts/spec-3-4-select-one-device-for-simultaneous-wake.md'

<frozen-after-approval reason="local iOS delivery record for the shared 3-I-4 contract">

## Shared contract

The cross-surface intent, acceptance criteria, ownership boundaries, and
approved arbitration decisions now live in the TUI repository's shared
contract:

`hermes-relay-tui/_bmad-output/implementation-artifacts/spec-3-4-select-one-device-for-simultaneous-wake.md`

This file records only the iOS implementation scope and evidence. It must not
become a second source of truth for the Home-service protocol or arbitration
policy.

## iOS implementation scope

The iOS foundation provides:

- opaque canonical wake-mapping references while retaining local row IDs for
  editing;
- positive per-Room arbitration priorities and deterministic validation;
- revisioned whole-house configuration snapshots with atomic-publish seams;
- typed `HomeServiceClient` read/publish operations and typed service errors;
- backward-compatible persistence and receipt matching for the new fields.

The existing per-Device setup editor remains a local projection until the
shared Home-service contract supplies the household configuration path.

## Code map

- `HermesRelay/Models/DeviceModels.swift` — canonical mapping references,
  arbitration priority, Home configuration snapshots, and revision semantics.
- `HermesRelay/Services/DeviceDiscoveryClient.swift` — typed Home-service
  configuration seam; no guessed production wire implementation.
- `HermesRelayTests/DeviceDiscoveryTests.swift` — canonical-ID, priority, and
  snapshot validation coverage.

## Verification

- Focused `DeviceDiscoveryTests`: 72 passed, 0 failed, 0 skipped on the iPhone
  17 Pro / iOS 26.5 simulator.
- Full iOS Simulator suite: 325 passed, 0 failed, 0 skipped.
- iOS Simulator test build: succeeded.
- macOS Debug build: succeeded.
- `git diff --check`: clean.

The production Home-service HTTP client, live arbitration engine, Device
credential handshake, and hardware/manual smoke evidence remain open in the
shared contract.

</frozen-after-approval>
