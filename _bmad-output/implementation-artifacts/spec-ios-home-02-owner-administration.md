---
title: 'IOS-HOME-02 (slice 3) — Decide Profile grants, see holders and unpair on iOS and macOS'
type: 'feature'
created: '2026-09-27'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/course-correction-2026-09-23.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-02.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-02-pair-and-connect.md'
---

## Intent

**Problem:** A grant to an owned Profile stays `pending_owner` until a client already holding that Profile approves it. The Apple client can only show "Waiting for the Profile owner to approve" and has no way to be that owner. Nobody can see which devices hold a Profile, revoke one, or forget a Home from the app.

**Approach:** Use the HOME-NW-17 device-authenticated Profile-grant routes (Home `docs/contracts/v1/README.md`, "Profile grants"):

- `GET /api/v1/profile-grants/pending` → `{"schema": 1, "pending": [holder view]}`
- `GET /api/v1/profile-grants/holders` → `{"schema": 1, "holders": [holder view]}`
- `POST /api/v1/profile-grants/{grant_id}/approve|reject|revoke` with `{"schema": 1}` → `{"schema": 1, "grant": {"grant_id", "status"}}`

A holder view is `grant_id`, `device_label`, `device_type`, `profile_label`, `status`, `bootstrap`, `this_device`, `created_at` (epoch seconds). Other devices never expose a device ID.

Add a per-Home **Manage** screen reached from Settings → Home pairing. It lists requests waiting for this device's approval (Approve / Reject), the devices holding each Profile this device holds (Revoke for other devices), and **Unpair this Home**.

## Decisions (proposed 2026-09-27, awaiting user confirmation)

1. **Unpair is local forgetting.** Home has no device-authenticated self-revoke; device revoke is admin-only and loopback-only. Unpair removes this Home's saved profiles, their transcripts, the pairing record and the Keychain credential. It says that the device stays listed on Home until removed from the Home page. This matches TUI-HOME-01.
2. **This device's own grant is not revocable from the holder list.** Revoking your own grant to an owned Profile would give up ownership with no way back except the admin. Unpair covers leaving.
3. **Home answers `401 unauthorized` both for a bad credential and for a decision this device may not make.** Examples are revoking another device's grant on a shared Profile, or deciding for a Profile this device no longer holds. After a `401` on an action, re-read the pending list. If that succeeds, show "Home did not allow this change" and leave the credential usable. If it also fails with `401`, apply the slice-1 "Pair again" behaviour.
4. **Entry point:** Settings → Home pairing lists each paired Home with Manage. No pending-count badge in this slice; Home offers no push, and polling is out of scope.

## Boundaries & Constraints

- Use exactly the five routes above and the existing credential/renewal path. Invent no other operation (no remote unpair, no self-revoke, no rename of other devices).
- Approve, Reject and Revoke are explicit user actions. Revoke asks for confirmation. Nothing is decided automatically or retried automatically.
- Device labels, Profile labels and grant IDs stay out of logs and diagnostics. The new wire types redact their `description`.
- Nothing from these routes is persisted; the screen reads on appear and after each action.
- `not_found` on a decision means the request expired (24 h), was decided elsewhere, or was revoked. Say so and refresh the list.
- iOS and macOS share the implementation.

## I/O & Edge-Case Matrix

| Situation | Result |
| --- | --- |
| Open Manage | Pending and holders fetched; loading state; content-free errors with Retry |
| This device holds no active grant on this Home | Empty explanation: nothing to approve until a Profile is granted to this device |
| Pending request | Row: device label, type, requested Profile, requested time; Approve / Reject |
| Approve / Reject succeeds | Row leaves pending; holders refreshed |
| Decision `404 not_found` | "This request expired or was already decided." List refreshed |
| Decision or revoke `401`, pending list still readable | "Home did not allow this change." Credential kept usable |
| Decision or revoke `401`, pending list also `401` | Pairing marked unusable; "Pair again with <host>." |
| Holders | Grouped by Profile label; "This device" badge; "Waiting for approval" for pending holders; "First device" for a bootstrap grant |
| Revoke another holder | Confirmation; `revoke`; list refreshed; that device's open claims are closed by Home |
| Home unreachable / `service_unavailable` | "Home is unreachable…" with Retry |
| Credential already unusable | Lists show "Pair again"; Unpair still available |
| Unpair | Confirmation naming the Home; profiles, transcripts, record and Keychain credential removed; if the selected profile was removed, the live surface resets like deleting the selected profile |

## Code Map

- `HermesRelay/Models/HomeClientPairingModels.swift` — `HomeProfileGrantHolder`, `HomeProfileGrantPendingList`, `HomeProfileGrantHolderList`, `HomeProfileGrantAction`, `HomeProfileGrantDecision` (strict keys, schema 1, redacted descriptions).
- `HermesRelay/Services/HomeClientService.swift` — `pendingProfileGrants`, `profileHolders`, `decideProfileGrant` on the protocol, URLSession and fake.
- `HermesRelay/Services/HomeClientPairingStore.swift` — `HomeClientClaimCoordinator.ownerOverview(pairingID:)` and `decideProfileGrant(pairingID:grantID:action:)` with the `401` disambiguation; `HomeOwnerAdministrationError`; `HomeClientPairingCoordinator` passthroughs and `unpair(pairingID:)`.
- `HermesRelay/Views/RelayConfigurationView.swift` — paired Homes with Manage in the Home pairing section; `RelayProfileListModel.unpair(pairingID:)`.
- New `HermesRelay/Views/HomeOwnerAdministrationView.swift` — `HomeOwnerAdministrationModel` and the screen (explicit `project.pbxproj` entries).
- `HermesRelayTests/HomeOwnerAdministrationTests.swift` — wire, coordinator, model and unpair tests with the fake service.

## Acceptance

- Given a device holding an owned Profile and another device's `pending_owner` grant, when the user taps Approve, then Home activates the grant and the requester's next Refresh gains the profile.
- Reject, Revoke, holders, `not_found`, `401` disambiguation, unreachable Home and Unpair behave as in the matrix.
- No grant ID, device label or credential reaches logs, diagnostics or non-Keychain files beyond the existing pairing record.

## Verification

- Focused XCTest (`HomeOwnerAdministrationTests`, `HomeClientPairingTests`), full iOS Simulator suite, macOS build.
- Live, iOS and macOS separately: approve a second client's pending grant from the phone; reject one; revoke a holder; see holders on a shared Profile; unpair and confirm the Home page still lists the device until removed there.

## Spec Change Log

- 2026-09-27: Drafted from Home `main` (`profile-grants` routes in `src/hermes_home/api/application.py`, rules in `domain/credentials.py`) and TUI-HOME-01 unpair precedent; implemented on `claude/ios-grant-approval-e7uc0p` pending the user's confirmation of the proposed decisions and a readiness review.
