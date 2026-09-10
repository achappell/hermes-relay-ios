---
title: 'Discover unconfigured household Devices'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '53b69bfe2c8abbad03e6f49c5700529e853fdf98'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** An iOS household administrator needs to identify a physical Device that is present but not yet trusted. Discovery must not quietly become approval: an unconfigured candidate must remain visibly inert until a later setup story grants it access.

**Approach:** Add an iOS Settings/device-administration surface backed by a typed, deterministic discovery client seam. Present discovered and approved Devices as separate collections; make the selected candidate's connecting, success, and failure states explicit; and preserve the candidate as unconfigured through every discovery path. Keep the production transport behind the seam until the shared Device discovery and handshake contract is resolved.

## Boundaries & Constraints

**Always:** Keep discovered/unconfigured and approved Devices visibly separate; identify the selected Device; show connecting rather than implying success from a list refresh; make successful connection visible; keep failures actionable while leaving the candidate unconfigured; use deterministic fake clients in tests; keep the voice conversation shell, relay profiles, and macOS target intact; keep diagnostics content-safe.

**Never:** Implement approval, Room setup, Wake Mappings, Ready state, revocation, credential storage, wake arbitration, or re-enrollment from this slice; reuse relay bearer-token storage as a physical Device credential; invent Hermes wire frames or a new device handshake; capture audio, submit a Hermes turn, or log prompts, responses, tokens, or audio; treat discovery or connection success as approval.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| DISCOVERY_WITH_MIXED_DEVICES | One approved Device and two unconfigured candidates returned by the fake client | Settings shows distinct approved and discovered sections; each candidate is labelled unconfigured/inert | Empty sections remain readable; no candidate is promoted |
| SELECT_UNCONFIGURED | User selects a discovered candidate | Candidate shows explicit connecting, then explicit connection success; it remains unconfigured and absent from approved/ready state | A successful transport event never grants access or creates a credential |
| LAN_UNAVAILABLE | Discovery transport reports that LAN discovery is unavailable | UI shows an actionable failure and offers the selected manual fallback path without changing trust state | Candidate remains inert; no silent retry loop or list-refresh claim |
| MANUAL_IDENTIFICATION | User supplies the fallback identifier for the same unconfigured Device | The matching candidate is shown as unconfigured and can enter the same explicit connecting/success path | Unknown or malformed identifier is rejected with a repair action |
| CONNECTION_FAILURE | Selected candidate cannot be connected | Candidate remains in the discovered/unconfigured list with a clear failure and retry/fallback action | No approval, credential, capture, wake, or Hermes side effect |
| INERT_GUARD | Any discovery result, selection, or connection completion | Fake side-effect counters for approval, credentials, capture, and Hermes turns remain zero | The UI state machine rejects any accidental promotion |

## Resolved Decisions

- **DISCOVERY_TRANSPORT:** Implement the iOS surface, state model, typed `DeviceDiscoveryClient` seam, and deterministic fakes now. Keep the production transport explicitly unavailable or adapter-only until Hermes/Device supplies the shared discovery and handshake contract. This slice must not create a second protocol.

</frozen-after-approval>

## Code Map

- `HermesRelayIOS/Views/ContentView.swift:99-142` -- current `NavigationStack` and relay-configuration sheet integration points; add the device-administration entry without disturbing the voice shell.
- `HermesRelayIOS/Views/RelayConfigurationView.swift:4-58,60-361` -- existing relay profile settings model and Form conventions; keep physical Devices separate from relay Profiles and bearer tokens.
- `HermesRelayIOS/HermesRelayIOSApp.swift:5-62` -- application-root dependency injection and support-directory setup; inject the discovery seam here if the surface is app-owned.
- `HermesRelayIOS/Models/RelayProfile.swift`, `HermesRelayIOS/Models/RelayProfileCollection.swift`, and `HermesRelayIOS/Services/RelayConfigurationStore.swift` -- explicit non-reuse boundary for relay identity and secure token persistence.
- `HermesRelayIOS/Services/HermesSessionClient.swift` and `HermesRelayIOS/Services/URLSessionHermesSessionClient.swift` -- existing Hermes voice transport; do not extend it with physical Device administration frames.
- `HermesRelayIOS.xcodeproj/project.pbxproj` -- hand-maintained project membership and target build phases for every new source/test file.
- `HermesRelayIOSTests/RelayConfigurationTests.swift` and `HermesRelayIOSTests/HermesRelayIOSTests.swift` -- deterministic XCTest, fake, and presentation-test patterns to follow.

## Tasks & Acceptance

**Execution:**
- [x] `HermesRelayIOS/Models/DeviceModels.swift` -- define physical Device identity and discovery/connection/configuration states with no credentials -- keep discovered candidates distinct from approved Devices.
- [x] `HermesRelayIOS/Services/DeviceDiscoveryClient.swift` -- define typed async discovery, connection, fallback, and failure seams -- prevent views from parsing frames or inventing transport behavior.
- [x] `HermesRelayIOS/ViewModels/DeviceDiscoveryModel.swift` -- own discovery, separate collections, selection, connecting, success, failure, and manual fallback state -- make every trust boundary explicit and testable.
- [x] `HermesRelayIOS/Views/DeviceDiscoveryView.swift`, `HermesRelayIOS/Views/RelayConfigurationView.swift`, and `HermesRelayIOS/Views/ContentView.swift` -- expose the iOS Settings flow with readable separate sections and explicit state presentation -- give the administrator a safe path from found to identified without implying approval.
- [x] `HermesRelayIOS/HermesRelayIOSApp.swift` and `HermesRelayIOS.xcodeproj/project.pbxproj` -- wire the client seam and register new files -- preserve iOS and macOS target integrity.
- [x] `HermesRelayIOSTests/DeviceDiscoveryTests.swift` and project membership -- cover the full matrix with deterministic fakes and zero side-effect assertions -- catch accidental promotion or hidden connection state.

**Acceptance Criteria:**
- Given iOS Settings is opened with one approved Device and two unconfigured candidates, when discovery runs, then approved and discovered/unconfigured sections are separate and each candidate's inert status and available action are readable.
- Given an unapproved candidate is selected, when connection progresses, then the UI shows connecting and then explicit success or actionable failure; success does not move the candidate to approved/ready state.
- Given LAN discovery is unavailable, when the fallback is used, then the same unconfigured candidate can be identified through the selected manual/QR path without granting access.
- Given any discovery or connection failure, when the administrator retries or chooses fallback, then the candidate remains unconfigured and no approval, credential, capture, wake, or Hermes-turn side effect occurs.
- Given the macOS target is built, when the slice is present, then the existing conversation and relay-profile configuration behavior remains unchanged and physical Device administration remains iOS-scoped.

## Implementation Notes

- Added an iOS-only Devices surface from Relay Configuration. Approved and discovered collections are rendered separately, and every discovered row remains explicitly unconfigured/inert after identity connection.
- Kept the production dependency as `UnavailableDeviceDiscoveryClient`: the app has a real typed seam, but no guessed LAN/QR protocol is shipped before the shared Hermes/Device discovery and handshake contract exists. Unsupported fallback is hidden and the error explains why.
- `DeviceDiscoveryModel` validates stable identifiers, filters misclassified and colliding identities, rejects mismatched manual/connection responses, guards overlapping discovery and stale connection completions, and treats cancellation as non-user-facing.
- The client contract documents a read-only identity boundary. Deterministic fakes expose approval, credential, capture, and Hermes-turn counters; the inert-guard tests assert that all remain zero.
- Added the iOS local-network usage declaration in the plist and both target configurations. Relay bearer-token storage, voice capture, Hermes turns, and macOS UI remain outside this slice.
- Added a Debug-only `-HermesRelayDeviceDiscoveryFixture` launch path for simulator smoke validation. It supplies one approved Device and two unconfigured candidates with deterministic success, failure, retry, and manual-identification outcomes; Release builds continue to use the unavailable production adapter.

## Spec Change Log

- 2026-09-09: Implemented the approved DEVICE-01 slice and recorded review triage and deferred transport work.

## Review Triage Log

| Finding | Verdict | Route | Evidence / decision |
|---|---|---|---|
| B1. The app injects an unavailable client, so the shipped screen cannot discover. | false | intent_gap | This is the approved `DISCOVERY_TRANSPORT` decision: ship the iOS surface and seam while production transport stays unavailable until the shared contract exists. |
| B2. LAN failure offers a manual fallback that the production client cannot complete. | medium | patch | Fixed by making the unavailable adapter report `supportsManualPairing == false` and mapping its error to an honest transport-not-configured message; deterministic adapters still exercise the fallback path. |
| B3. A failed refresh retains old devices and success state, leaving stale candidates selectable. | false | defer | Retaining the last known inert snapshot keeps retry available, shows the current error, and never changes trust. Revocation, expiry, and stale-snapshot policy are outside this slice. |
| B4. Overlapping discovery can let an older response overwrite a newer one. | medium | patch | Fixed with a monotonically increasing discovery request ID and `testLatestDiscoveryWinsWhenRequestsOverlap`. |
| B5. Rows can be selected again after success or refresh. | false | intent_gap | Re-identification is an allowed, visible read-only action; only connecting is disabled. The slice does not define a one-shot connection or approval transition. |
| B6. Unstructured tasks have no timeout or explicit transport cancellation policy. | maybe-false | defer | No live production adapter exists yet. Swift task cancellation is handled without a user-facing failure; timeout and transport ownership belong with the future shared adapter contract. |
| B7. A receipt containing only an ID is not cryptographic identity proof. | maybe-false | defer | The receipt is an adapter boundary, not a protocol. Its documentation requires the shared handshake to confirm identity; attestation and proof requirements must be resolved with Hermes/Device. |
| B8. The client connection contract could hide side effects. | false | intent_gap | The protocol documentation explicitly forbids approval, credential issuance, wake, capture, and Hermes turns, and the fake exposes zero counters for those effects. |
| B9. Manual identifiers accept malformed non-empty values. | medium | patch | Fixed by rejecting whitespace/empty identifiers, requiring an exact response ID match, and testing mismatched responses and blank input. |
| B10. iOS success does not prove the external Device visibly acknowledged the connection. | medium | defer | Device-side acknowledgement belongs to the unresolved shared handshake/transport and cannot be invented in this iOS-only slice. |
| B11. Release generated Info.plist lacked the local-network usage description. | medium | patch | Fixed by adding the accurate usage string to `Development-Info.plist` and Debug/Release target settings. |
| B12. Tests covered the model but not the UI, and fakes lacked side-effect counters. | medium | patch | Added deterministic side-effect counters and an iOS `UIHostingController` construction test; full interactive smoke remains a separate verification step. |
| E1. An empty identifier can enter the discovered collection. | medium | patch | Fixed with `HouseholdDevice.hasValidIdentifier`, collection filtering, and a focused test. |
| E2. Out-of-order discovery responses can overwrite state. | medium | patch | Same request-ID guard as B4, covered by the overlap test. |
| E3. A failed refresh leaves stale state visible. | false | defer | The retained snapshot is visibly paired with the current failure and remains inert; snapshot invalidation policy is not part of DEVICE-01. |
| E4. A candidate can be selected while discovery is running. | medium | patch | Fixed with an explicit `.discoveryInProgress` guard and a test proving the fake client is not called. |
| E5. A late connection result can promote a candidate after refresh removes it. | medium | patch | Fixed by checking both the discovery request ID and current unconfigured membership before applying the receipt; covered by a suspended-connection test. |
| E6. Cancellation can surface as a connection/discovery failure. | low | patch | Discovery catches `CancellationError` silently and the focused test confirms no user-facing error. Connection results are also ignored when their discovery generation is stale. |
| E7. A manual response for a different Device can be accepted. | medium | patch | Fixed with exact requested-ID matching and an `unexpectedResponse` failure test. |
| E8. Zero side effects and UI state transitions were not verified. | medium | patch | Fakes now track the four prohibited effect categories and tests assert `.zero`; connection tests cover connecting, success, failure, and retry state values. |
| V1. The full iOS Settings flow was not exercised interactively. | maybe-false | defer | The iOS view now has deterministic hosting coverage, but a visual/manual smoke pass still requires a booted iOS simulator and belongs in the board verification evidence. |
| V2. Approved/unconfigured ID collisions were untested. | medium | patch | Added filtering and a focused collision test so an approved identity cannot remain in the candidate collection. |
| V3. Manual pairing of an already-approved identity was untested. | medium | patch | Added an approved-identity guard and a focused test proving the identity is rejected without promotion. |

Surviving work is grouped by route:

- `patch`: truthful fallback capability, identifier validation, stale-result guards, connection-in-progress protection, local-network declaration, and deterministic safety/UI coverage are implemented and covered by focused tests.
- `defer`: production timeout/cancellation ownership, handshake identity proof, Device-side acknowledgement, and interactive iOS smoke evidence require the future transport contract or a booted simulator.
- `intent_gap`: no approved intent gap remains for this slice; the unavailable production adapter is deliberate.

## Design Notes

Discovery is a transport observation, not a trust transition. The model therefore carries an explicit unconfigured state even after a successful connection; only a future approval/setup slice may add a Device to the approved collection or create credentials. The manual fallback is intentionally represented as an adapter seam rather than a guessed QR format or device protocol.

## Verification

**Commands:**
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' -only-testing:HermesRelayIOSTests/DeviceDiscoveryTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- 19 focused discovery tests passed.
- `xcodebuild -quiet -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- 265 iOS simulator tests passed, including 20 Device tests.
- `xcodebuild -quiet -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` -- iOS simulator build succeeded.
- `xcodebuild -quiet -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` -- macOS target build succeeded.
- `git diff --check` plus the changed-file credential/audio/signing-artifact scan passed.

**Manual checks:**
- Interactive iOS Settings smoke completed on an iPhone 17 Pro running iOS 26.5 with the Debug fixture launch argument. Configure relay → Manage household Devices showed one approved Kitchen Display and two separate unconfigured/inert candidates. Identifying Hallway Puck rendered `Connection confirmed` and `Hallway Puck responded. It remains unconfigured.`; it stayed in Discovered Devices and never moved to Approved Devices. Identifying Study Display rendered the actionable `Retry` state and connection failure message. Manual pairing accepted `unconfigured-study-display` and returned `Study Display found. It remains unconfigured.` The transient `.connecting` state remains covered by deterministic model tests; no approval, setup, ready, credential, capture, or Hermes-turn UI effect occurred. The unsigned simulator also showed the pre-existing Keychain entitlement diagnostic in the conversation shell; it did not affect the Devices flow.

**Verification update — 2026-09-09:**
- `xcodebuild` through XcodeBuildMCP with `-only-testing:HermesRelayIOSTests/DeviceDiscoveryTests` -- 22 Device Discovery tests passed.
- XcodeBuildMCP full iOS simulator XCTest run -- 267 tests passed, 0 failed.
- `xcodebuild` macOS target build -- succeeded; Xcode emitted only its existing destination/build-number warnings.
- `xcodebuild` Release iOS simulator build -- succeeded, confirming the Debug fixture does not prevent the production configuration from compiling.
- XcodeBuildMCP Debug build/run with `-HermesRelayDeviceDiscoveryFixture` -- iOS simulator app build and launch succeeded; the observed states are recorded above.
