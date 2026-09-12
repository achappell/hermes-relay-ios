---
title: 'Approve and configure a household Device'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Discovery can prove that a physical Device is present, but it must
not make that Device an active household doorway. The administrator needs a
deliberate approval boundary followed by a visible, ordered setup flow.

**Approach:** Add a typed administration seam and a deterministic SwiftUI
wizard. After a verified discovery connection, explicit approval moves the
Device into an authorized-but-inactive setup-pending state. The wizard then
requires a Room, at least one valid unique Wake Mapping, and final ready
confirmation before publishing configuration and showing the Device as ready.

## Boundaries & Constraints

**Always:** Keep approval separate from readiness; keep the order `Room` →
`Wake Mappings` → `Ready`; reject blank or duplicate mappings before publish;
show setup-pending/inactive state; use deterministic fake administration in
tests and Debug simulator smoke; validate every adapter receipt against the
requested Device ID.

**Never:** Invent Device wire frames, publish real configuration, store raw
Device Credential bytes in source/tests/logs, activate a Device after approval
alone, silently use another Profile, or implement revocation/re-enrollment
from this slice. A successful adapter approval is an opaque assertion that the
future adapter provisioned the individual credential; credential material does
not cross the seam.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| EXPLICIT_APPROVAL | Connected unconfigured candidate | Approval action calls the administration seam and enters Room setup | Failure leaves the candidate unapproved and shows an actionable error |
| APPROVED_PENDING_SETUP | Approval succeeds, setup incomplete | Device is shown as approved but setup pending/inactive | Cancelling does not mark the Device ready |
| ROOM_REQUIRED | Blank or whitespace-only Room | Continue is rejected | Show a repair message and do not advance |
| MAPPING_REQUIRED | No Wake Mappings | Continue is rejected | Show that at least one mapping is required |
| MAPPING_VALIDATION | Blank, malformed, or duplicate wake phrase/profile fields | Publish is blocked | Explain the invalid or duplicate mapping without a transport call |
| READY_CONFIRMATION | Valid Room and one or more unique mappings | Configuration is published through the typed seam and Device becomes ready | Mismatched or failed receipt leaves setup pending/inactive |
| INERT_GUARD | Approval succeeds but setup is abandoned | No ready state, wake, capture, Hermes turn, or second Profile side effect | The pending state remains explicit |

## Resolved Decisions

- **ADMINISTRATION_TRANSPORT:** Add the typed approval/configuration boundary
  and deterministic fake now. Keep the production adapter unavailable until
  Hermes and the physical Device settle credential issuance, configuration
  publication, offline behavior, and re-enrollment semantics.
- **PROFILE_REFERENCE:** The local editor stores a trimmed, opaque Hermes
  Profile identifier in each mapping. It does not retrieve, switch, or invent
  Profile protocol operations; profile-picker UX can replace this field when
  the shared contract is settled.
- **CREDENTIAL_BOUNDARY:** The approval receipt contains only the verified
  Device ID. The adapter owns future Keychain-backed credential provisioning;
  raw credential material is never returned to the view model or fixtures.

## Code Map

- `HermesRelayIOS/Models/DeviceModels.swift` -- typed setup phases, Wake
  Mappings, setup configuration, and approval/configuration receipts.
- `HermesRelayIOS/Services/DeviceDiscoveryClient.swift` -- typed
  `DeviceAdministrationClient`, unavailable production adapter, and Debug
  fixture.
- `HermesRelayIOS/ViewModels/DeviceDiscoveryModel.swift` -- setup wizard state,
  validation, explicit approval, and authorized-but-inactive projection.
- `HermesRelayIOS/Views/DeviceDiscoveryView.swift` -- entry action and ordered
  Room → Wake Mappings → Ready wizard.
- `HermesRelayIOS/HermesRelayIOSApp.swift`, `ContentView.swift`, and
  `RelayConfigurationView.swift` -- administration seam injection.
- `HermesRelayIOSTests/DeviceDiscoveryTests.swift` -- deterministic approval,
  validation, receipt, and inert-state coverage.

## Acceptance Criteria

- Given a connected unconfigured Device, when the user taps Approve, then the
  administration seam receives the exact Device identity and the UI enters
  Room setup only after approval succeeds.
- Given an approved Device with incomplete setup, when the wizard is closed or
  the app is still on Room or Wake Mappings, then the Device is visibly
  setup-pending/inactive and is not ready.
- Given a blank Room or zero mappings, when the user continues, then the wizard
  stays on the current step and makes the missing requirement actionable.
- Given one or more mappings, when any wake phrase is blank or duplicated, then
  final configuration is blocked before the administration seam is called.
- Given a valid Room and unique mappings, when the user confirms Ready, then the
  administration seam receives the complete configuration and a matching
  receipt promotes the Device to ready; a failure leaves it inactive.
- Given the macOS target is built, when the slice is present, then the existing
  conversation and relay-profile behavior remains unchanged and physical
  Device administration remains iOS-scoped.

</frozen-after-approval>

## Implementation Notes

- Added DeviceAdministrationClient as a typed seam for approval and ordered
  setup. The shipped production adapter remains unavailable until the shared
  Device credential and configuration contracts are settled.
- Approval accepts only a connected, still-unconfigured candidate and promotes
  it to an authorized-but-inactive local state after an exact-ID receipt.
- Added an in-memory DeviceSetupModel and SwiftUI wizard with explicit Room →
  Wake Mappings → Ready phases. Room and mapping validation runs before
  transport, and the final confirmation revalidates before publishing.
- Wake Mapping identifiers are trimmed opaque Hermes Profile references. The
  slice does not retrieve, switch, or invent Profile protocol operations.
- Added deterministic Debug administration behavior behind
  -HermesRelayDeviceDiscoveryFixture; no raw Device Credential bytes cross the
  seam or appear in tests, fixtures, logs, or source.
- Added an application-support JSON DeviceSetupDraftStore keyed by Device ID.
  Cancel and system dismissal preserve only the incomplete Room, Wake Mapping,
  and wizard-step draft; Resume rehydrates it without making the Device active.
  Ready deletes the draft after an exact-ID configuration receipt, while an
  explicit, confirmed Discard removes it without touching approval.
- Approval and setup behavior is injected from the app through the existing
  iOS Device discovery flow. macOS receives no Device UI or transport.

## Verification

- Focused DeviceDiscoveryTests: 39 passed, 0 failed, 0 skipped.
- Full iOS Simulator suite: 284 passed, 0 failed, 0 skipped.
- macOS Debug build: exited 0.
- iOS Simulator Debug build: succeeded.
- Debug Simulator smoke on iPhone 17 Pro: connected and approved Hallway Puck,
  entered Room and Wake Mappings, cancelled, and observed Resume setup with
  the saved fields. After relaunching the app, the fixture still required a
  fresh approval; re-approving Hallway Puck rehydrated the saved draft. The
  confirmed Discard action removed the draft and restored Set up.
- git diff --check: clean.
