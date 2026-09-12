- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Bound buffered audio-file memory before accepting arbitrarily large fallback payloads.
  evidence: `audioFileBuffer` still accumulates every `audio_file_chunk` until `audio_file_end`; this pre-existing transport/output boundary requires an explicit product limit and failure policy beyond the current slice.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define timeout and cancellation ownership for the production Device discovery adapter.
  evidence: DEVICE-01 handles Swift task cancellation without surfacing a false user failure, but no live adapter exists yet; the shared transport contract must define timeouts, cancellation propagation, and retry policy.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define the shared Device handshake and identity-proof requirements for connection receipts.
  evidence: DEVICE-01 accepts only an adapter receipt whose ID matches the requested candidate; cryptographic identity proof and attestation are intentionally deferred until Hermes and the physical Device share a settled contract.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define the Device-side acknowledgement and observable success semantics for identity connection.
  evidence: The iOS model exposes explicit connecting/success states, while external acknowledgement must come from the future Device transport and cannot be fabricated by this client slice.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-ios-capture-acknowledgement-and-live-transcription.md`
  summary: Replace the `for _ in 0..<N { await Task.yield() }` synchronization pattern across `VoiceSessionCoordinatorTests.swift` with a deterministic wait.
  evidence: The pattern (10+ occurrences, N ranging 3-100) is inherently probabilistic. This story's own new test tipped one instance (N=3, since raised to 20) into deterministic failure purely from binary-size/scheduling shift, with no logic change and no shared state — confirmed by stash/pop bisection. Raising the count reduces recurrence risk but does not remove it; a repo-wide move to awaiting the coordinator's internal task handle or an `XCTestExpectation` would, but that's a larger change than any single verify-only story's scope.

## Resolved on 2026-09-11

- The recent transcript rail now preserves the active assistant identity after
  Hermes sends `turnComplete` and until the voice coordinator finishes draining
  scheduled playback. `ConversationStore` retains the assistant ID through the
  playback lifecycle, while `VoiceSessionCoordinator` settles it at Complete
  or playback failure. A regression test observes the projected entry as live
  while `output.finish()` is gated, then verifies the ID clears after settling.
  Focused verification and the full iOS simulator suite pass (320/320); the
  macOS target compiles with signing disabled.

## Future iOS UX, design, and brand tickets captured on 2026-09-11

These are local follow-up records from the simulator UX run. They are not new
upstream story identities or external board items while board reconciliation
remains paused; promote one into the appropriate local story artifact when
selected.

- ticket: `IOS-UX-F1`
  status: `verified`
  summary: Make unavailable and unconfigured states lead with the action the user can actually take.
  source_spec: `_bmad-output/implementation-artifacts/spec-5-1-ios-independent-conversation-doorway.md`
  evidence: The simulator showed the large idle HUD as “Ready / Tap the microphone to begin” while no usable relay was configured or reachable; Configure/Retry was visually secondary.
  implementation_evidence: `ConversationDoorwayState` now distinguishes unconfigured, disconnected, connecting, reconnecting, connected, and unavailable states; the HUD exposes Configure relay, Connect, or Retry as the primary recovery action; voice controls are gated on a connected relay; cached drafts remain visible with configure/connect guidance. Focused doorway tests pass, the iPhone 17 Pro simulator smoke shows “Not configured” with no voice controls, and the Configure relay action opens the configuration sheet.
  acceptance: No-profile, disconnected, and unavailable states expose a truthful primary action; voice capture is disabled or replaced with an explicit setup/retry path; cached drafts remain visible and recoverable.

- ticket: `IOS-UX-F2`
  status: `verified`
  summary: Reconcile the live session immediately after deleting the selected profile.
  source_spec: `_bmad-output/implementation-artifacts/spec-5-1-ios-independent-conversation-doorway.md`
  evidence: Deleting the active simulator profile removed it from configuration, but the live surface continued to show that profile as “Unavailable” until app restart.
  implementation_evidence: `RelayConfigurationView` now invokes `ConversationStore.clearSelectedProfile()` only after a successful deletion of the selected profile; the reset cancels reconnect work, disconnects transport, clears active profile/session identity, transcript, draft, unconfirmed-turn state, and the deleted profile's persistence handle. The iPhone 17 Pro simulator showed the live surface change immediately from an unavailable disposable profile to “No Profile selected / Not configured” while the configuration sheet remained open. Focused store/configuration tests passed.
  acceptance: Deleting the selected profile clears the active session/profile identity immediately, returns the main surface to “No Profile selected,” disables retry/send/capture, and leaves no stale profile-bound conversation state exposed.

- ticket: `IOS-UX-F3`
  status: `verified`
  summary: Replace configuration save-banner validation with field-level guidance.
  source_spec: `_bmad-output/implementation-artifacts/spec-5-1-ios-independent-conversation-doorway.md`
  evidence: Saving an empty form surfaced a bottom error banner, then exposed the token requirement only after the endpoint was supplied; the invalid field was not focused automatically.
  implementation_evidence: `RelayConfigurationDraft` now exposes field-keyed validation errors; `RelayConfigurationView` groups endpoint and device identity fields, shows inline endpoint/token guidance before save, focuses the first invalid field, and explains stored-token keep/replace semantics. Focused configuration tests pass (30/30), the full iOS simulator suite passes (319/319), macOS Debug build passes, and the iPhone 17 Pro simulator smoke confirmed both empty-submit and invalid `http://` endpoint errors beside the relevant fields.
  acceptance: Required endpoint/token rules are visible before save; the first invalid field receives focus and an adjacent error; stored-token replacement/removal remains unambiguous; device identity fields have explicit labels and grouping.

- ticket: `IOS-UX-F4`
  status: `verified`
  summary: Clarify household Device discovery recovery and empty states.
  source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  evidence: The Devices sheet repeats approval/inert-state explanation across empty sections, while discovery failure relies on a refresh icon as the only retry affordance.
  implementation_evidence: `DeviceDiscoveryModel` now separates discovery failures from action errors; `DeviceDiscoveryView` presents one concise identity/approval boundary, contextual approved and discovered empty states, a dedicated Discovery unavailable section, and a labelled Retry discovery action with accessibility identifiers. Focused Device discovery tests pass (67/67), the full iOS simulator suite passes (320/320), the iOS simulator smoke confirms the production-unavailable state and retry action, and the macOS target compiles with signing disabled; a signed macOS build remains blocked by the current shell's missing Mac Development certificate/private key.
  acceptance: Empty, unavailable, and retrying states explain the next step once; discovery failure provides a labeled retry action; approval and identity-confirmation boundaries remain explicit.

- ticket: `IOS-DESIGN-F1`
  status: `verified`
  summary: Run a deliberate visual design pass across the iOS doorway.
  source_spec: `_bmad-output/implementation-artifacts/spec-5-1-ios-independent-conversation-doorway.md`
  design_record: `_bmad-output/implementation-artifacts/ios-visual-design-pass.md`
  depends_on: [`IOS-UX-F1`, `IOS-UX-F2`, `IOS-UX-F3`, `IOS-UX-F4`]
  scope: Review hierarchy, state presentation, setup/profile management, offline/recovery surfaces, voice and hands-free controls, transcript/history, typography, spacing, color, motion, and accessibility as one system.
  implementation_evidence: The approved Night Console direction is now implemented with semantic adaptive color assets and `VisualDesignTokens.swift`; the conversation doorway uses a midnight canvas, explicit profile/state/recovery hierarchy, structural panels for transcript and explanation surfaces, and restrained Liquid Glass for grouped controls and interactive voice actions. Voice, hands-free, status, transcript, configuration, and Device setup surfaces now consume the shared state palette; reduced-motion behavior remains frozen for the visualizer and transcript reveal. iOS simulator build succeeds, the full iOS simulator suite passes (320/320), light and dark simulator screenshots were reviewed, and the macOS target compiles with signing disabled. The design record remains the source of truth for later screenshot/Dynamic Type/VoiceOver expansion.
  acceptance: Produce a state-by-surface design decision record, a compact visual language/token set, and prioritized screen recommendations; implement the approved visual hierarchy while preserving protocol, privacy, and fail-closed boundaries.

- ticket: `IOS-BRAND-F1`
  status: `verified`
  summary: Create and wire the Hermes Relay app icon set.
  source_spec: `_bmad-output/implementation-artifacts/spec-5-1-ios-independent-conversation-doorway.md`
  design_record: `_bmad-output/implementation-artifacts/ios-visual-design-pass.md`
  depends_on: [`IOS-DESIGN-F1`]
  evidence: The approved abstract signal-orb master plus default/light, dark, and tinted 1024px renditions are tracked in `HermesRelay/Assets.xcassets/AppIcon.appiconset`; the target is wired to `AppIcon`; the installed simulator app shows the current mark; the archive succeeds; and the App Store Connect-style arm64 IPA export contains all three renditions, an Apple Distribution signature, and a store provisioning profile with beta reporting enabled.
  acceptance: Approve a master icon direction and palette; provide the required iOS icon variants, including light/dark/tinted treatment where supported; add the asset catalog and target wiring; verify the installed simulator icon and archive/TestFlight packaging without committing generated build products.

## Future macOS distribution tickets captured on 2026-09-11

These are local follow-up records requested during the macOS packaging pass. They
are intentionally scoped to the direct macOS distribution channel; iOS update
delivery remains App Store-managed. They are not external board items while
board reconciliation remains paused.

- ticket: `MACOS-DIST-F1`
  status: `future`
  summary: Produce a signed, notarized, and Gatekeeper-valid macOS DMG release artifact.
  scope: Build the Release macOS app for the supported arm64 and x86_64 architectures; package it in a versioned DMG with the Hermes Relay app icon, stable volume/app naming, and documented installation path; sign the app with Developer ID, notarize and staple the DMG, and publish checksums/release metadata without committing generated artifacts.
  dependencies: [`IOS-BRAND-F1`]
  acceptance: The release workflow emits a versioned universal DMG; the app bundle contains `AppIconMac.icns` and its Release dSYM; Developer ID signing, notarization, and stapling succeed with configured credentials; `spctl`/Gatekeeper accepts the mounted app on a clean supported Mac; the workflow fails clearly when signing or notarization credentials are absent; no tokens, certificates, archives, or DMGs enter the repository.

- ticket: `MACOS-DIST-F2`
  status: `future`
  summary: Add a secure macOS Check for Updates flow backed by the signed release channel.
  scope: Define the macOS update feed/channel and version policy; expose a user-initiated Check for Updates command in the app; present checking, up-to-date, update-available, offline, and failed states; download and install only a release whose metadata and artifact signature verify; require explicit user confirmation before replacing the app. iOS is out of scope because App Store delivery owns its update path.
  dependencies: [`MACOS-DIST-F1`]
  acceptance: The macOS app can check the configured feed without a live relay; an available newer version shows version and release notes before confirmation; current, unavailable, malformed, unsigned, and unreachable feeds produce truthful recoverable states; update installation never executes an arbitrary or unsigned download; feed/channel configuration and signing keys are documented; fake-feed tests cover version comparison, signature rejection, cancellation, offline recovery, and successful handoff to the signed installer/DMG flow.

## Resolved on 2026-09-09

- Epic 1 iOS physical-device validation pass for Stories 1.1 and 1.2 completed. Evidence is recorded in `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md` and the corresponding external story records. Deterministic tests remain authoritative for speaker/WAV fallback and late-event timing branches that were not observed live.
- DEVICE-01 interactive iOS Devices smoke completed with the Debug fixture on the iPhone 17 Pro / iOS 26.5 simulator. The approved/unconfigured split, successful identity confirmation without promotion, connection failure with retry, and manual identification without approval were observed; the transient connecting state remains covered by deterministic tests. The production discovery adapter remains unavailable by design until the shared Device transport contract exists.

## Deferred from: code review of hermes-relay-ios-review-spec.XXXXXX.XV2EBX33l3 (2026-09-09)

- macOS permission failures expose a typed Settings action, but the shared macOS `ContentView` supplies no Settings URL; defer until macOS permission-recovery UX and URL handling are explicitly scoped.
