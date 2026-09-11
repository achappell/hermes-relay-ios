---
title: 'Revoke access and require verified re-enrollment'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-5-fail-closed-for-unavailable-or-revoked-identities.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="local delivery record for the selected iOS slice">

## Intent

**Problem:** A household administrator needs to remove one physical Device's
access without leaving a powered or reachable Device looking Ready. If
revocation or re-enrollment is uncertain, the iOS client must show the
uncertainty and keep the Device inactive.

**Approach:** Add explicit, receipt-validated revoke and re-enroll operations to
the existing Device administration seam. Persist a local revocation-pending
state before the revoke request, promote to revoked only after an exact receipt,
and require explicit re-enrollment followed by the existing ordered Room, Wake
Mappings, and Ready setup flow. A re-enrollment receipt never promotes local
readiness by itself.

**Always:** Keep revoked and revocation-pending Devices inactive; validate the
Device ID in every receipt; preserve a visible retry path for failed or
unconfirmed revocation; require explicit administrator action before
re-enrollment; keep credentials opaque and out of models, logs, tests, and
artifacts.

**Never:** Do not invent physical Device wire frames, credential storage,
credential bytes, upload, audio capture, Hermes turns, remote undo, or
Device-side enforcement. The shipped production administration adapter remains
unavailable until the shared physical Device contract exists.

## Acceptance Criteria

- Given a configured Device, when the administrator chooses Disconnect and
  confirms, then iOS begins local revocation-pending state before remote
  administration and the Device is not active during the operation.
- Given revocation returns an exact Device receipt, when the operation
  completes, then iOS persists revoked state, clears pending mapping edits,
  shows access revoked, and leaves the Device inactive.
- Given revocation fails, is unavailable, or returns a mismatched receipt, when
  the operation completes, then iOS persists revocation-pending state, shows a
  visible retry/error path, and never presents the Device as Ready.
- Given a reachable Device whose local state is revoked or revocation-pending,
  when discovery runs again, then reachability does not trigger verification or
  restore active state.
- Given a revoked Device, when the administrator explicitly chooses
  re-enrollment and receives an exact receipt, then iOS opens ordered setup and
  keeps the Device revoked/inactive until Room, Wake Mappings, and Ready are
  completed.
- Given re-enrollment fails or returns a mismatched receipt, when the result is
  applied, then the Device remains revoked and inactive with an actionable
  error.
- Given the macOS target is built, when this slice is present, then existing
  conversation and relay-profile behavior remains unchanged and Device
  administration remains iOS-scoped.

## Code Map

- `HermesRelayIOS/Models/DeviceModels.swift` — revocation-pending and revoked
  identity/setup labels plus opaque revoke/re-enrollment receipts.
- `HermesRelayIOS/Services/DeviceDiscoveryClient.swift` — typed revoke and
  re-enrollment seams with unavailable and deterministic debug implementations;
  no physical Device protocol.
- `HermesRelayIOS/ViewModels/DeviceDiscoveryModel.swift` — fail-closed local
  revocation, receipt validation, explicit re-enrollment gating, and ordered
  setup handoff.
- `HermesRelayIOS/Views/DeviceDiscoveryView.swift` — destructive Disconnect
  confirmation, retryable pending state, explicit re-enrollment action, and
  re-enrollment setup copy.
- `HermesRelayIOSTests/DeviceDiscoveryTests.swift` — confirmed, failed,
  mismatched, reachable, and ordered re-enrollment coverage.

## Implementation Notes

- Revocation is persisted locally as `revocationPending` before the
  administration client is called. Remote failures therefore cannot leave the
  next launch looking Ready.
- Only a receipt for the requested Device ID promotes the local state to
  `revoked`; any other response leaves the Device pending and inactive.
- Explicit re-enrollment is available only for a locally revoked Device. Its
  successful receipt changes no readiness state; the existing setup model must
  publish the complete configuration before the Device can become verified.
- The production adapter still throws `transportUnavailable`. Debug fixtures
  and fakes return identity-only receipts and never contain credential material
  or audio.

## Verification

- Focused `DeviceDiscoveryTests`: 66 passed, 0 failed, 0 skipped on the iPhone
  17 Pro / iOS 26.5 simulator.
- Full iOS Simulator XCTest target: 313 passed, 0 failed, 0 skipped.
- iOS Simulator Debug build: succeeded with exit code 0.
- macOS Debug build: succeeded with exit code 0.
- Manual simulator smoke on 2026-09-10: the final build launched, Configure
  Relay opened, and Manage household Devices reached the honest unavailable
  adapter state without a crash. The shipped production Device adapter has no
  physical administration contract, so confirmed Disconnect/re-enrollment
  cannot be exercised against live hardware in this slice; deterministic
  receipt and failure coverage is authoritative for those branches.
- `git diff --check` passed. Changed-file review found no credentials, bearer
  values, audio captures, signing artifacts, or generated build products.

</frozen-after-approval>
