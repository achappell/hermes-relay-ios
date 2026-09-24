---
title: 'IOS-HOME-02 (slice 1) — Pair iOS and macOS with a Home and connect through a client claim'
type: 'feature'
created: '2026-09-24'
status: 'in-progress'
baseline_commit: 'b23d1f87fa4b35af0a83f9afd259a052157da665'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/course-correction-2026-09-23.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-02.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Home mode on iOS and macOS needs a Device credential and a conversation handle pasted in by an operator. A handle expires about 90 seconds after issue if it is not opened, and the app has no pairing, credential renewal or claim flow. HOME-NW-17 (Home `7fb5e2a`) now provides a pairing link, enrollment, `client_grants`, renewal and `POST /api/v1/client-claims`.

**Approach:** Pair from a `hermes-home://pair?home=…&code=…` link, or from a typed short code plus Home address. Submit a `client_claim` enrollment, show the confirmation code, and poll consume until approval. Store the credential in Keychain, renew it automatically, and choose a Profile by `grant_id`. On every connect, make a fresh client claim (`session: new`) and open the existing STD-4 bridge with it. Session management and owner administration are deferred IOS-HOME-02 work (see `deferred-work.md`).

## Decisions (2026-09-24, user)

- **One saved profile per grant.** One pairing per Home holds a single Keychain credential, keyed by pairing rather than by app profile. Every active grant appears in Saved profiles as its own app profile, shown as `<grant label> · <Home host>`, with its own transcript. When a grant becomes active later (for example after owner approval), a refresh adds its profile. The credential is removed when a Home's last profile is removed.
- **Keep the transcript, add a divider.** A new Home session on an existing profile keeps earlier local messages and inserts a visible "New conversation" divider. Earlier messages are never sent to Hermes.
- **In-app QR scanner on iOS.** It is added alongside the link and typed-code entry. It needs a camera permission string. If the camera is denied or unavailable, the app falls back to typed entry. macOS uses a pasted link or a typed code only.
- **Spec size.** The spec is kept whole at about 3,000 tokens; the user accepted the size risk.

## Boundaries & Constraints

**Always:**
- Enrollment request:
  - `type` is `ios` or `macos`;
  - `requested_rooms` is `[]` and `requested_capabilities` is `["client_claim"]`;
  - `secure_storage` is `platform_secure_store`;
  - `endpoint_id` is a stable per-install, per-Home UUID, so that pairing again replaces the previous generation.
- The Home address must be `https`, with no credentials, query or fragment. The bridge route is derived as `wss://<same host:port>/api/v1/bridge/ws`.
- Credentials, `conversation_handle`, `grant_id`, `device_id` and codes stay out of logs, transcripts, diagnostics and non-Keychain files. The exceptions are `grant_id` and `device_id` in the pairing record, which are non-secret.
- Renew during the renewal window before making a claim; Home closes live claims on renewal. Use `generation` and a fresh `request_id`.
- Send `conversation.close` on explicit Disconnect, on Profile switch, and when a paired profile is removed.
- A turn that may have reached Hermes is never replayed. A reconnect within the grace period uses the existing `conversation.reconnect`. If continuity is lost, the app says so and offers a deliberate new conversation.
- The legacy operator-handle setup (`HomeLiveSetupView`) and IOS-HOME-01 room administration keep working unchanged.

**Never:**
- Show, store or send a Profile ID or Standard Session ID.
- Send a room, wake mapping or acoustic evidence on the client-claim route.
- Switch mode automatically or fall back after a Home outage.
- Build session listing/resume, owner approvals/holders, remote unpair/revoke, or Standard-only mode (IOS-STD-01).
- Change the sibling repositories.
- Claim live or physical acceptance that has not been run.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Link opened | Valid `hermes-home://pair` URL | Pairing sheet prefilled; request submitted; confirmation code shown | Malformed or non-https link: specific message, nothing submitted |
| Typed code | Code (any case, dash optional) plus https Home address | Same as link | — |
| Waiting | consume `409 approval_pending` | "Waiting for approval on the Home page"; poll about every 2 s until `expires_at`; cancellable | — |
| Rejected / expired | `403 rejected`, `410 expired_or_consumed` | Terminal message; offer to start again | No partial credential stored |
| Approved | `200` with credential and `client_grants` | One Keychain credential per Home; pairing saved; one app profile per active grant; `pending_owner` grants shown as waiting for the owner; Home mode selected only after the first live `ready` | Keychain failure: pairing is not saved |
| Connect | Paired, active grant | Renew if eligible → read device configuration `revision` → claim `session: new` → `conversation.open` | `stale_configuration`: refresh once and retry |
| Claim denied | `grant_pending`, `profile_unavailable`, `client_claim_unavailable`, `claim_limit` | Plain, specific disconnected state; no retry loop | — |
| Credential invalid | `401 unauthorized` or credential expired | "Pair again with <Home>" state | Credential marked unusable |
| Route pin | First `ready` after pairing | Route identity recorded; later claims require that exact route | Mismatch → `identityMismatch` |

</frozen-after-approval>

## Code Map

- `HermesRelay/Services/HomeConfigurationMigration.swift`:
  - `HomeLiveActivation` and the `HomeConfigurationMigration` journal are the pattern for selecting Home only after a live `ready`.
  - `migrate` requires a legacy token, so paired profiles need a sibling activation path that writes the `homeSelected` journal without one.
  - `HomeLiveConfiguration` and `JSONHomeLiveConfigurationStore` are the legacy handle store. Keep them.
- `HermesRelay/Services/HomeCredentialStore.swift`: `KeychainHomeCredentialStore.provision` and `verifiedReadBack` are reused. `HomeCredentialReference.validate` requires exactly 90 days and a 14-day renewal window, so derive `issuedAt` from Home's `expires_at`. It also pins the account to `HomeCredentialKeychain.account(for: profileID)`. A paired profile needs a pairing-keyed account, `device-credential.pairing.<pairingID>`, resolved through the pairing record, and the legacy per-profile account must stay valid.
- `HermesRelay/Models/HomeBridgeModels.swift`:
  - `HomeCredentialKeychain`, `HomeApprovedRoute`/`validate` (wss plus `/api/v1/bridge/ws`), and `HomeConversationClaim` are relevant here.
  - Home's route class is always `home` (Home `endpoint.py` `BridgeRoute`).
  - `HomeApprovedRouteProvider` is where the bridge client re-checks the route.
- `HermesRelay/Services/HomeBridgeSessionClient.swift`:
  - `URLSessionHomeBridgeSessionClient.open` compares `ready.route` with the claim identity; route pinning plugs in here.
  - `allowedMethods` lacks `conversation.close`, which needs to be added along with a `close(binding:)` request.
  - The auth header is `Device <credential>`.
- `HermesRelay/Services/FakeHomeBridgeSessionClient.swift`: `AppHomeConversationClaimProvider` and `AppHomeBridgeSessionClientFactory` are the composition point for the new claim provider. Keep the Debug `-HomeBridgeFake` path.
- `HermesRelay/ViewModels/ConversationStore.swift`:
  - `loadConfiguredClient` fetches the claim at load, around lines 259–290. Paired profiles must claim inside `connectHome` (line 366), because claims are single-use and expire after 90 s.
  - Disconnect and Profile switch paths must call close.
- `HermesRelay/Views/RelayConfigurationView.swift`: the Home bridge section, around line 480, is the entry point for "Pair with Home". The saved-profile list shows paired profiles.
- `HermesRelay/HermesRelayApp.swift`: wiring, plus `.onOpenURL` for `hermes-home`.
- `HermesRelay/Development-Info.plist` and `Hermes Relay.xcodeproj/project.pbxproj`:
  - Register the `hermes-home` URL scheme in both configurations. Release uses a generated Info.plist.
  - Add `NSCameraUsageDescription` (Debug plist and Release `INFOPLIST_KEY_NSCameraUsageDescription`).
  - New Swift files need explicit pbxproj entries; the project uses no synchronized groups.
- Home contract: `hermes-relay-home/docs/contracts/v1/README.md` §Personal clients, and `api/application.py`:
  - enrollment, consume and renew bodies;
  - `_material_payload`;
  - `_client_grant_views` (`grant_id`, `label`, `status`, `available`).

## Tasks & Acceptance

**Execution:**
- [ ] `HermesRelay/Models/HomeClientPairingModels.swift` (new) -- link and code parsing, the Home base-URL rules, the wire models for enrollment, consume, renew, device configuration and client claim (strict keys, as in STD-4), the typed denial codes, and a `HomeClientPairing` record (Home URL, endpoint ID, device ID, generation, selected grant, pinned route ID) -- this is the contract surface.
- [ ] `HermesRelay/Services/HomeClientService.swift` (new) -- a URLSession HTTP client for enrollment, consume, renew, configuration and claims behind a protocol, plus a fake -- this keeps transport deterministic in tests.
- [ ] `HermesRelay/Services/HomeClientPairingStore.swift` (new) -- a JSON store of the non-secret pairing records, plus a pairing coordinator: submit → poll → Keychain provision → save pairing → live `ready` activation with route pin → journal `homeSelected` -- this is the crash-safe pairing flow.
- [ ] `HermesRelay/Services/FakeHomeBridgeSessionClient.swift` -- a claim provider that renews if due, reads the revision, claims and returns a `HomeConversationClaim`; it falls through to the legacy store -- this replaces pasted handles.
- [ ] `HermesRelay/Services/HomeBridgeSessionClient.swift` -- route pin on first `ready` and `conversation.close` -- this closes the lifecycle.
- [ ] `HermesRelay/ViewModels/ConversationStore.swift` -- claim per connect for paired profiles, denial states, and close on disconnect/switch -- this is the connect path.
- [ ] `HermesRelay/Views/HomePairingView.swift` (new), `RelayConfigurationView.swift`, `HermesRelayApp.swift` -- the pairing sheet (link/code entry, confirmation code, waiting, terminal states, a per-grant profile summary with `pending_owner` waiting, and a refresh action) and the URL handler -- this is the UI.
- [ ] `HermesRelay/Views/HomePairingScannerView.swift` (new, iOS only) -- an AVFoundation QR scanner that accepts only `hermes-home://pair` payloads; it falls back to typed entry when the camera is denied -- the user chose this.
- [ ] `HermesRelay/ViewModels/ConversationStore.swift` divider -- a local-only "New conversation" marker when a fresh Home session starts on a profile that has history -- the user chose this.
- [ ] `HermesRelayTests/HomeClientPairingTests.swift` (new) -- every row of the I/O matrix, plus renewal-before-claim ordering and the absence of secrets from persisted JSON -- this is the deterministic evidence.
- [ ] `_bmad-output/implementation-artifacts/validation-ios-home-02.md` (new) -- a record that keeps the local, merge, iOS live and macOS live gates separate -- this is required by the story.

**Acceptance Criteria:**
- Given a pairing link, when the page approves, then the app connects and completes a typed turn without any pasted credential or handle.
- Given a paired profile past its renewal point, when it connects, then it renews before claiming and stays paired.
- Given any persisted file or log, then no credential, handle, Profile ID or Standard Session ID appears.
- Given an existing legacy or operator-handle Home profile, then it behaves exactly as before.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `xcodebuild test -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HermesRelayTests/HomeClientPairingTests` -- expected: pass (CI `macos-26`; there is no Xcode in the Linux container)
- The full iOS simulator test run and the macOS build, as in `.github/workflows/ci.yml` -- expected: pass
- `git diff --check` -- expected: clean

**Manual checks:**
- Live iOS and macOS pairing against the deployed Home (HOME-NW-17 is not yet deployed): record setup, typed and voice turns, stop, and reconnect separately per platform, or mark them deferred.
