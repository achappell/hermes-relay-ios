---
title: 'Validate unique Wake Mappings and Profile-specific publish state'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-2-approve-and-configure-device.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="local delivery record for the selected iOS slice">

## Intent

**Problem:** A ready Device needs an editable Wake Mapping configuration, but a
failed or offline edit must not replace the last verified mapping or imply that
an unconfirmed Hermes Profile is active.

**Approach:** Persist the last verified Device configuration separately from an
optional pending edit. Validate normalized wake phrases before the administration
seam is called, publish the complete Room and Profile-specific mapping through
the existing typed seam, and promote only an exact semantic receipt. Local row
UUIDs remain editor state and are not treated as Device wire identity.

## Boundaries & Constraints

**Always:** Reject blank mappings and duplicate wake phrases before publishing;
keep the verified mapping active while an edit is pending, offline, failed, or
unconfirmed; show pending state in the Device list and editor; use deterministic
stores and administration fakes in tests; keep Profile identifiers opaque.

**Never:** Invent Device wire frames, upload audio, change relay bearer-token
storage, silently select another Hermes Profile, or mark a failed edit as
verified. The production Device adapter remains unavailable until the shared
Device configuration contract is settled.

## Acceptance Criteria

- Given duplicate wake phrases after trimming and case/diacritic normalization,
  when Amanda publishes an edit, then validation blocks the administration call
  and explains the duplicate.
- Given a valid mapping to one Hermes Profile, when the Device returns a receipt
  matching the Device ID, Room, ordered wake phrases, and Profile identifiers,
  then the edit becomes the verified active configuration.
- Given a failed, offline, or mismatched publish, when the editor closes or the
  app reloads, then the previous verified mapping remains active, the edit is
  retained as pending, and the UI labels the update as unapplied.
- Given a pending edit is reverted to the verified mapping, when the editor
  closes, then the pending state is cleared without another publish.
- Given a verified Device, when its row is shown, then the administrator can
  open the editor; a pending edit is labelled for review and remains active on
  the old mapping until confirmation.
- Given the macOS target is built, when this slice is present, then existing
  conversation and relay-profile behavior remains unchanged and Device
  administration remains iOS-scoped.

## Code Map

- `HermesRelayIOS/Models/DeviceModels.swift` -- persisted verified/pending
  configuration state, publication state, and semantic configuration receipts.
- `HermesRelayIOS/Services/DeviceDiscoveryClient.swift` -- application-support
  JSON store and existing typed administration seam; no new wire protocol.
- `HermesRelayIOS/ViewModels/DeviceDiscoveryModel.swift` -- publish validation,
  pending-state preservation, exact receipt matching, and Device-list status.
- `HermesRelayIOS/Views/DeviceDiscoveryView.swift` -- Edit/Review update entry,
  mapping editor, remove action, and visible verified/pending messaging.
- `HermesRelayIOS/HermesRelayIOSApp.swift`, `ContentView.swift`, and
  `RelayConfigurationView.swift` -- persistent store injection through the iOS
  settings flow.
- `HermesRelayIOSTests/DeviceDiscoveryTests.swift` -- duplicate, failure,
  pending, revert, receipt, persistence, and active-state coverage.

## Implementation Notes

- Added an application-support `JSONDeviceConfigurationStore` keyed by Device
  ID. It stores the verified configuration and optional pending edit with
  complete file protection on iOS.
- Added `DeviceConfigurationModel` for editing and publishing mappings. Failed
  and mismatched publishes preserve the verified configuration and persist the
  pending edit; reverting an edit clears stale pending state.
- Receipt promotion compares publishable values only. It deliberately ignores
  local `DeviceWakeMapping` UUIDs while requiring the exact Device ID, Room,
  order, wake phrase, and Hermes Profile identifiers.
- The shipped production adapter remains unavailable. The Debug fixture and
  unit tests remain deterministic and do not contain credentials, prompts,
  responses, or audio.

## Verification

- Focused `DeviceDiscoveryTests`: 49 passed, 0 failed, 0 skipped on the iPhone
  17 Pro / iOS 26.5 simulator.
- Full iOS Simulator suite: 295 passed, 0 failed, 0 skipped.
- iOS Simulator Debug build: succeeded.
- macOS Debug build: succeeded.
- `git diff --check`: clean.
- Changed-file scan found no bearer values, credentials, audio captures,
  signing artifacts, or generated build files.

## Review gate

- The interactive smoke pass completed on 2026-09-10 through XcodeBuildMCP on
  the iPhone 17 Pro / iOS 26.5 simulator after the fixture launch argument was
  delivered reliably.
- The smoke observed legacy Hallway Puck state rehydrating after reopening
  Devices, Edit/Review opening for the configured row, a pending mapping edit
  preserving the verified mapping, and a successful fixture publish returning
  the row to Ready.
- Deterministic tests cover duplicate rejection, failed/offline/mismatched
  publish, pending persistence, revert clearing, and exact Profile-specific
  receipt promotion. The shipped production adapter remains unavailable until
  the shared Device configuration contract is settled.
- This slice is closed; no credential, production Device transport, or
  cross-platform administration behavior is implied by the fixture smoke.

</frozen-after-approval>
