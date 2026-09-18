---
title: 'IOS-HOME-01 — Add the iOS Home configuration adapter for approved Devices'
type: 'feature'
created: '2026-09-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: '8c97215e276adfb446ed0bd99896eb6e1d677bae'
context:
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/home-live-evidence.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-pairing-adapter.md'
  - '{project-root}/HermesRelay/Models/HomeBridgeModels.swift'
  - '{project-root}/HermesRelay/Services/HomeConfigurationMigration.swift'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** iOS has Device discovery and administration seams plus an approved
Home route, but no client boundary for Home's household configuration. Without
one, local setup can promote stale state while Home's revision and failure
semantics remain disconnected from the UI.

**Approach:** Add a typed Home adapter using the selected approved route, a
dedicated Home-admin Keychain credential, strict schema-1 GET/PUT translation,
and expected-revision writes. Home-backed setup and editing promote local state
only after a complete Home response is validated. Home owns configuration,
credential authority, and arbitration.

**Scope decision:** This is the configuration-first slice for an already
approved Device. Physical enrollment, opaque per-Device credential issuance or
consumption, expiry, revocation, and re-enrollment remain behind the existing
`DeviceAdministrationClient` and belong to a later pairing slice. This slice
must not imply that those lifecycle operations are implemented.

## Boundaries & Constraints

**Always for Home-backed operations:** Use Home v1's complete snapshot and
revision as authority; send/receive the `schema: 1` configuration envelope;
preserve Home's household-wide mapping IDs/names and one `profile_id` per
Device; bind the admin credential to the approved household route; validate
all returned fields before promotion; preserve verified state and pending edits
after stale, invalid, unauthorized, or unavailable operations. Home config
validation never replaces Device identity verification.

**Never:** Put credentials in source, URLs, JSON snapshots, logs, diagnostics,
or errors; reuse the Hermes bearer; fabricate Rooms or Device records; rename,
add, remove, or grant Home mappings in iOS, or expose Home's global mapping
catalog as an editable per-Device authority; invent a second protocol or wake
arbiter; let discovery or Home configuration silently approve a Device; or make
macOS depend on iOS-only Device administration UI.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| VALID_FETCH | Complete schema-1 Home snapshot | Strictly decoded, semantically valid domain snapshot | Invalid shape is typed invalid-response; no partial state |
| VALID_PUBLISH | Existing Home Device, valid edit, current revision | Complete candidate is sent; returned snapshot and revision become the Home-backed basis | Any mismatched `id`, `name`, `room_id`, `profile_id`, `priority`, capability, mapping, or revision stays pending |
| STALE_PUBLISH | Home rejects `expected_revision` with 409 | Prior verified state remains active; edit remains pending; reload is offered | Typed revision-conflict guidance |
| RELOAD_RECONCILIATION | Home changes or omits the selected Device | Verified local projection follows Home while an unsaved edit remains pending; an omitted/ineligible Device is inactive | Stale local state is never promoted as current |
| AUTH_OR_UNAVAILABLE | Missing/rejected credential, route mismatch, or unavailable Home | No new configuration becomes active; prior safe state remains visible | Decode stable Home error codes into actionable typed guidance |
| INERT_DISCOVERY | Unconfigured or identity-only discovery result | Device remains unapproved and inactive | No credential, wake, capture, or Hermes side effect |

</frozen-after-approval>

## Code Map

- `HermesRelay/Models/DeviceModels.swift` -- Home snapshot,
  canonical mapping projection, Room/device validation, revision state, and
  receipt comparison; local row UUIDs remain editor-only.
- `HermesRelay/Services/DeviceDiscoveryClient.swift` -- typed Home
  client, `/api/v1/configuration` wire envelope, route resolution, strict
  decoding/encoding, stable error mapping, timeout, and redirect refusal.
- `HermesRelay/Services/HomeCredentialStore.swift`,
  `HermesRelay/Models/HomeBridgeModels.swift:31-75`,
  `HermesRelay/Services/HomeConfigurationMigration.swift:1-145`, and
  `HermesRelay/Services/RelayConfigurationStore.swift` -- separate
  profile-scoped Home-admin secret, full approved-route binding, and selected
  Profile ownership. Do not mix this with relay or Device credentials.
- `HermesRelay/ViewModels/DeviceDiscoveryModel.swift` -- Home-backed
  setup/edit promotion, existing-record precondition, reload reconciliation,
  pending preservation, and identity fail-closed behavior; retain the explicit
  legacy fallback when Home is not configured.
- `HermesRelay/Views/DeviceDiscoveryView.swift`,
  `HermesRelay/Views/RelayConfigurationView.swift`,
  `HermesRelay/Views/ContentView.swift`, and `HermesRelay/HermesRelayApp.swift`
  -- Home status/credential UI and
  injection. Physical Device UI remains iOS-only; shared settings must stay
  free of iOS-only dependencies.
- `HermesRelayTests/DeviceDiscoveryTests.swift` and
  `HermesRelayTests/RelayConfigurationTests.swift` -- deterministic
  Home transport, Keychain, route-binding, snapshot, mapping, conflict,
  reload, receipt, and inert-state coverage.

## Tasks & Acceptance

**Execution:**

- [x] Align domain and wire models with Home v1: complete Rooms, global
  canonical mappings, one Profile per Device, capabilities, priorities, and
  revision. Legacy local files may decode, but Home wire data may not omit or
  fabricate Rooms or IDs.
- [x] Complete the Home client and credential boundary: exact envelopes,
  approved-route/household binding, schema validation, stable `error.code`
  mapping for `invalid_request`, `unauthorized`, `not_found`,
  `revision_conflict`, and `service_unavailable`, timeout, and no secret
  leakage; unknown codes fail closed.
- [x] Complete Home-backed model/UI behavior: require an existing Home Device
  record, present the global mapping catalog as read-only, reject unsupported
  mapping edits or multi-Profile projections, reconcile reloads, preserve
  pending edits, and never bypass Device identity verification. Keep the legacy
  Device-administration fallback explicit.
- [x] Extend deterministic XCTest coverage for every matrix case, returned
  revision and field checks, route changes, missing Devices, capability/profile
  mismatches, legacy migration, and prohibited side effects.

**Acceptance Criteria:**

- A valid Home response produces only a complete, schema-valid snapshot. A
  Home-backed publish sends the full candidate with `expected_revision`; its
  returned revision is not older than the expected revision and every
  publishable Device field (`id`, `name`, `room_id`, `profile_id`, `priority`,
  `capabilities.wake_claim`) plus the global mapping catalog matches before
  promotion.
- A stale, malformed, unauthorized, or unavailable operation never replaces
  the verified basis. A pending edit remains recoverable, and stable Home error
  codes produce actionable guidance without exposing response secrets.
- Home-backed setup requires an approved Device already present in Home's
  snapshot. An absent Device, unknown Room, disabled wake capability, or
  unsupported mapping/profile projection cannot create a local Ready state or
  fabricate a Home record.
- Home-backed mapping names and IDs are read-only canonical Home data; local
  editing cannot rename, add, remove, or grant them, and a multi-Profile local
  projection is rejected before network publication.
- Reload reconciles the selected Device's Home-backed projection and revision
  without overwriting an unsaved pending edit; an omitted or ineligible Device
  becomes inactive. Home configuration does not promote a revoked, unavailable,
  or unverified identity.
- The Home-admin credential is stored only in its profile- and
  household-bound Keychain record. Leaving the field blank preserves it;
  explicit removal clears it; route/household changes require rebinding. The
  Hermes credential is unchanged.
- Discovery alone remains inert, and the macOS target builds with existing
  conversation, Profile, and Keychain behavior intact.

## Implementation Notes

- Home eligibility is persisted separately from Device identity. Rediscovery
  cannot restore a Home-ineligible Device, and failed eligibility persistence
  leaves the Device inactive with an error.
- Home-admin Keychain records use schema v2 and bind to the complete approved
  route. Older records decode only to require credential re-entry; they are not
  sent to Home.
- Legacy Device administration is used only when the selected Profile has no
  approved Home route. A configured but unavailable Home route stays on the
  Home path and fails closed.
- Physical enrollment and live Home-service behavior remain out of scope; Home
  transport and failure cases use deterministic fakes.
- `HomeConfigurationSnapshot` is a local projection, not a second Home
  authority. Persist only selected-device verified/pending state and the Home
  revision; fetch Home before Home-backed publication.
- Home v1 exposes a household-wide mapping catalog and one Profile per Device.
  Local mapping rows may retain editor identity, but cannot become Device Grant
  authority; grants and live arbitration remain Home-owned.
- The wire contract is `GET`/`PUT /api/v1/configuration` with a `schema: 1`
  envelope. PUT carries `expected_revision`; the candidate snapshot carries no
  client revision and the returned snapshot is the only publish receipt.
- A Home transport outage during an edit keeps the last verified configuration
  visible and the edit pending. Existing Device identity state still controls
  whether operation is active or inactive.

## Spec Change Log

- 2026-09-16 -- Locked configuration-first scope; clarified endpoint-side
  credential ownership, legacy fallback, Home mapping ownership, route binding,
  reload reconciliation, and identity verification boundaries.
- 2026-09-16 -- Human chose to keep the full spec so its coupled authority and
  fail-closed requirements remain together.
- 2026-09-16 -- Implemented the approved slice, patched all 18 triaged review
  groups, and recorded focused/full simulator and macOS build evidence. The
  Edge Case Hunter limitation remains explicit below.
- 2026-09-17 -- Completed the Device Management simulator smoke, aligned the
  turn-ID fallback regression test with the current correlation contract, and
  reran the full iOS suite and macOS build successfully. The local tracker is
  now `done`.

## Verification

**Implementation validation (recorded 2026-09-16):**

- Focused `DeviceDiscoveryTests` and `RelayConfigurationTests` on iPhone 17 Pro
  / iOS 26.5 simulator: **144 tests passed, 0 failures**.
- Full iOS simulator XCTest target on iPhone 17 Pro / iOS 26.5:
  **425 tests passed, 0 failures**.
- macOS arm64 target build with signing disabled: **passed**.
- `git diff --check` against the recorded baseline: **passed**. The original
  implementation diff's credential-pattern scan found no matches; it
  contained only expected Swift source/tests and local BMad artifacts, with no
  audio, signing, generated build products, or unrelated edits.

**Review validation (2026-09-17):**

- Focused `DeviceDiscoveryTests` and `RelayConfigurationTests` on the iPhone 17
  Pro / iOS 26.5 simulator: **144 tests passed, 0 failures**.
- Full iOS simulator XCTest target on iPhone 17 Pro / iOS 26.5: **426 tests
  passed, 0 failures**. The separate STD-4 fallback regression test now uses
  an absent event correlation ID and verifies turn-ID fallback plus the
  completed turn binding; mismatched non-empty correlation IDs remain rejected.
- The focused fallback test passed: **1 test passed, 0 failures**.
- Debug simulator build/run succeeded; the macOS arm64 target build with
  signing disabled also succeeded.
- `git diff --check`: **passed**.

**PR branch validation (2026-09-17; based on `origin/main` at `5cb989d`):**

- Debug simulator build/run on iPhone 17 Pro: **passed**.
- Full iOS simulator XCTest suite: **446 tests passed, 0 failures**.
- Focused Home suites plus the fallback regression: **145 tests passed, 0 failures**.
- macOS arm64 build with signing disabled: **passed**.
- `git diff --check`: **passed**.

**Manual smoke:**

- Installed and launched the Debug discovery fixture on the iPhone 17 Pro
  simulator. The unconfigured screen showed “No Profile selected” and “Not
  configured”; the composer and send button were disabled.
- Opened Configure Relay → Household Devices → Manage household Devices. The
  Devices screen showed the approved Kitchen Display separately from the
  unconfigured Hallway Puck and Study Display, both labeled “Unconfigured and
  inert.” No Device was identified, approved, or configured.
- Valid, stale, malformed, unauthorized, and unavailable Home behavior is
  covered by deterministic XCTest fakes; no live Home endpoint or physical
  Device enrollment was used.

## Review Triage Log

The Edge Case Hunter did not return findings: its first session stalled, and a
replacement session also stalled after a finalize request. The two completed
review layers and a direct audit were triaged below; the unavailable layer is a
review limitation, not evidence of a clean pass.

| ID | Source | Finding | Verdict and evidence |
|---|---|---|---|
| V1 | Verification Gap | PUT serialization test omits the mapping catalog and Device ID, Room ID, and priority. | `medium` — patched; `testHomeServicePublishesCompleteConfigurationWithExpectedRevision` asserts the revision, complete catalog, and full Device fields in the PUT body. |
| V2 | Verification Gap | Ready confirmation lacks a regression test for Device identity verification and its failure path. | `medium` — patched; `testHomeBackedReadyDoesNotActivateWhenDeviceIdentityVerificationFails` proves a failed identity receipt cannot activate the Device. |
| V3 | Verification Gap | Home outage preservation is tested at the adapter, not the model/store boundary. | `medium` — patched; `testHomeTransportFailureKeepsVerifiedBasisAndPersistsPendingEdit` checks the retained verified basis and persisted pending edit. |
| V4 | Verification Gap | Blank Save and explicit Remove are not tested through a shared form-action seam. | `medium` — patched; `testHomeAdminCredentialFormPreservesBlankSaveAndRemovesExplicitly` covers both actions through the form seam. |
| V5 | Verification Gap | Admin credentials are bound to a household label, not the full approved route. | `high` — patched; `testHomeAdminCredentialBindingRejectsAnyChangedApprovedRoute` checks endpoint/identity changes, and `testLegacyHomeAdminCredentialRecordRequiresReEntry` rejects old unbound records. |
| B1 | Blind Hunter | The app always injects Home, making the legacy Device-administration branch unreachable when a profile has no Home route. | `medium` — patched; setup/editor tests prove no-route fallback, while `testConfiguredHomeFailureNeverFallsBackToLegacyAdministration` proves configured Home errors stay fail-closed. |
| B2 | Blind Hunter | A later discovery can re-verify local Device state after Home marked the Device absent or wake-disabled. | `high` — patched; `testHomeIneligibleDeviceIsNotRestoredByLaterDiscoveryVerification` pins rediscovery gating to persisted Home eligibility. |
| B3 | Blind Hunter | A pending Room edit keeps an obsolete read-only mapping projection after Home changes its catalog. | `medium` — patched; `testHomeReloadRebasesPendingRoomAndMappingProjectionToLatestCatalog` verifies Home-owned fields rebase while a valid pending Room survives. |
| B4 | Blind Hunter | The HTTP adapter accepts a snapshot revision different from `expectedRevision`. | `medium` — patched; `testHomePublishRejectsSnapshotRevisionThatDoesNotMatchPrecondition` verifies rejection before transport sends a request. |
| B5 | Blind Hunter | Profile identifiers are normalized during receipt comparison but compared raw during encoding. | `medium` — patched; `testHomeRoomIDsAndProfileIDsArePreservedVerbatim` covers exact Home Profile values across setup/edit and wire handling. |
| B6 | Blind Hunter | Home Room IDs are trimmed before lookup and candidate construction. | `medium` — patched; `testHomeRoomIDsAndProfileIDsArePreservedVerbatim` and `testHomeWireAcceptsOpaqueIdentifiersWithoutApplyingAnUndocumentedGrammar` preserve opaque IDs. |
| B7 | Blind Hunter | The default URLSession transport follows redirects for authenticated GET and full-replacement PUT requests. | `high` — patched; `testHomeURLSessionRedirectDelegateRefusesRedirects` verifies redirect refusal. |
| B8 | Blind Hunter | The invalid-response message says no changes were applied. | `medium` — patched; `testInvalidHomePublishResponseExplainsThatOutcomeIsUnknown` checks uncertainty and reload guidance. |
| B9 | Blind Hunter | Home reconciliation suppresses local persistence errors and still reports success. | `medium` — patched; `testHomeEligibilityPersistenceFailureReturnsInactiveWithAnError` proves write failure is surfaced and leaves the Device inactive. |
| B10 | Blind Hunter | Deleting a Profile removes its relay token but leaves the new Home-admin Keychain item. | `medium` — patched; `testDeletingProfileAlsoRemovesItsHomeAdminCredential` checks cleanup with Profile deletion and error handling. |
| B11 | Blind Hunter | Completing live Home setup does not refresh the Home-admin credential state in the parent form. | `medium` — patched in `RelayConfigurationView`: Home activation reloads the credential state for the selected Profile; the Device Management screen is now verified, but no live Home activation was attempted. |
| B12 | Blind Hunter | An empty Home mapping catalog leaves an enabled Device stuck behind “Add a Wake Mapping” while the Add control is hidden. | `low` — patched; `testEmptyHomeWakeMappingCatalogShowsHomeOwnedAction` verifies actionable Home-owned guidance. |
| B13 | Blind Hunter | Identifier validation accepts whitespace-only Room, Device, and mapping IDs. | `medium` — patched; `testHomeWireRejectsWhitespaceOnlyIdentifiers` rejects blank-only IDs while `testHomeWireAcceptsOpaqueIdentifiersWithoutApplyingAnUndocumentedGrammar` preserves meaningful opaque values. |

| Group | Members | Route | Smallest required action | Outcome and evidence |
|---|---|---|---|---|
| G1 | V1 | `patch` | Assert every serialized Home mapping and Device field in the PUT test. | Patched; `testHomeServicePublishesCompleteConfigurationWithExpectedRevision` asserts the full replacement body. |
| G2 | V2 | `patch` | Assert Ready calls Device verification and remains inactive on a rejected receipt. | Patched; `testHomeBackedReadyDoesNotActivateWhenDeviceIdentityVerificationFails`. |
| G3 | V3 | `patch` | Exercise a Home transport failure through the model and verify persisted state. | Patched; `testHomeTransportFailureKeepsVerifiedBasisAndPersistsPendingEdit`. |
| G4 | V4 | `patch` | Extract and test the credential form action so blank preserves and explicit removal deletes. | Patched; `testHomeAdminCredentialFormPreservesBlankSaveAndRemovesExplicitly`. |
| G5 | V5 | `patch` | Bind the credential record and store API to the approved route as well as Profile. | Patched; route-change and v1 re-entry tests cover the binding. |
| G6 | B1 | `patch` | Use legacy administration only when no Home route is configured; keep configured Home failures fail-closed. | Patched; setup/editor fallback tests and configured-failure test cover both branches. |
| G7 | B2 | `patch` | Persist Home eligibility and gate rediscovery on its last authoritative value. | Patched; `testHomeIneligibleDeviceIsNotRestoredByLaterDiscoveryVerification`. |
| G8 | B3 | `patch` | Rebase Home-owned mapping fields while preserving a still-valid pending Room edit. | Patched; `testHomeReloadRebasesPendingRoomAndMappingProjectionToLatestCatalog`. |
| G9 | B4 | `patch` | Require the local snapshot revision to equal the request precondition. | Patched; the mismatched-revision test verifies no request is sent. |
| G10 | B5 | `patch` | Validate and compare Home Profile identifiers consistently and exactly. | Patched; `testHomeRoomIDsAndProfileIDsArePreservedVerbatim`. |
| G11 | B6 | `patch` | Preserve selected Home Room IDs verbatim; normalize only entered Room labels. | Patched; exact Room-ID and opaque-ID tests cover the boundary. |
| G12 | B7 | `patch` | Use a URLSession delegate that refuses HTTP redirects. | Patched; `testHomeURLSessionRedirectDelegateRefusesRedirects`. |
| G13 | B8 | `patch` | Describe an invalid PUT response as an unknown outcome and direct the user to reload. | Patched; `testInvalidHomePublishResponseExplainsThatOutcomeIsUnknown`. |
| G14 | B9 | `patch` | Surface a failed reconciliation write instead of reporting success. | Patched; `testHomeEligibilityPersistenceFailureReturnsInactiveWithAnError`. |
| G15 | B10 | `patch` | Delete the Home-admin Keychain item with its Profile. | Patched; `testDeletingProfileAlsoRemovesItsHomeAdminCredential`. |
| G16 | B11 | `patch` | Reload credential state after live Home route activation. | Patched in the Home activation callback; manual Device Management traversal is verified, while live Home activation remains unverified. |
| G17 | B12 | `patch` | Give actionable guidance when Home's read-only catalog is empty. | Patched; `testEmptyHomeWakeMappingCatalogShowsHomeOwnedAction`. |
| G18 | B13 | `patch` | Reject blank-only identifiers without imposing a grammar on meaningful opaque IDs. | Patched; whitespace-only rejection and opaque-ID acceptance tests cover the boundary. |
