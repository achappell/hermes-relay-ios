---
title: 'Fail closed for unavailable or revoked Device identities'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-validate-unique-wake-mappings-and-profile-specific-publish-state.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="local delivery record for the selected iOS slice">

## Intent

**Problem:** A locally cached Device configuration must never make a Device
look ready when its identity, credential, or mapped Hermes Profiles have not
been freshly verified. An unavailable or revoked Device must remain visibly
inert and must not silently regain access because it is reachable or because a
stale configuration file survived relaunch.

**Approach:** Add a typed verification receipt to the existing Device
administration seam. Persist the last known identity state, but require a
fresh verified receipt after discovery before iOS presents a configured Device
as active. Unavailable, revoked, mismatched, and transport-unverified states
remain visible and fail closed; no Device wire protocol or credential material
is invented here.

**Always:** Require exact Device and configuration identity for a verified
receipt; treat missing or stale verification as unavailable; preserve the last
verified mapping for inspection without treating it as active; distinguish
unavailable from revoked; keep retry/verification explicit; keep Profile IDs
opaque and keep credentials out of models, logs, tests, and artifacts.

**Never:** Do not create a Device transport, revoke credentials, re-enroll a
Device, substitute another Profile, capture audio, submit a Hermes turn, or
claim that a Puck enforces the policy. Device-side enforcement belongs to the
paired Puck story and verified revocation/re-enrollment belongs to 3-I-6.

## Acceptance Criteria

- Given a persisted configured Device without a fresh verification receipt,
  when iOS discovers it, then the Device is visibly verification-required or
  unavailable and is not presented as active or ready.
- Given verification returns an exact Device/configuration receipt with all
  mapped Profiles available, when verification completes, then iOS presents
  the Device as Ready (or Update pending while retaining the verified mapping).
- Given verification reports an unavailable or revoked identity, when the
  result is applied, then iOS shows the corresponding state, permits no
  active Device operation, and does not fall back to another Profile.
- Given verification returns a mismatched Device or configuration, when the
  result is applied, then iOS fails closed and retains the prior verified
  configuration only as non-active cached context.
- Given a revoked Device is reachable later, when discovery or verification
  runs again, then reachability does not restore Ready state; explicit
  re-enrollment remains required and is out of scope for this slice.
- Given the macOS target is built, when this slice is present, then existing
  conversation and relay-profile behavior remains unchanged and Device
  administration remains iOS-scoped.

## Code Map

- `HermesRelayIOS/Models/DeviceModels.swift` — identity verification state,
  receipt, and fail-closed setup labels.
- `HermesRelayIOS/Services/DeviceDiscoveryClient.swift` — typed verification
  seam and unavailable/debug implementations; no wire protocol. Debug-only
  launch arguments can force unavailable or revoked verification for visual
  smoke coverage.
- `HermesRelayIOS/ViewModels/DeviceDiscoveryModel.swift` — fresh verification,
  stale-cache downgrade, exact receipt matching, and visible state changes.
- `HermesRelayIOS/Views/DeviceDiscoveryView.swift` — verification/retry
  affordances and non-interactive revoked presentation.
- `HermesRelayIOSTests/DeviceDiscoveryTests.swift` — deterministic stale,
  exact, unavailable, revoked, mismatch, and reachability regression coverage.

## Verification

- Focused XCTest: `DeviceDiscoveryTests`, 56 tests passed with 0 failures.
- Full iOS XCTest target: 302 tests passed with 0 failures on the iPhone 17 Pro
  iOS Simulator.
- macOS target: `xcodebuild build` succeeded for the native macOS destination.
- Manual simulator smoke through XcodeBuildMCP, using the Debug-only fixture
  arguments:
  - the discovery fixture launched and the Devices surface showed the approved
    Hallway Puck as verified/Ready;
  - unavailable verification showed `Unavailable · Inactive` with a `Retry`
    action and no active operation;
  - revoked verification showed `Revoked · Re-enrollment required`, a
    non-interactive row, and the explicit re-enrollment message.
- `git diff --check` passed. No Device transport, credentials, audio captures,
  or generated build products were added.

</frozen-after-approval>
