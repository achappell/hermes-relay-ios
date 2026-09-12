# Epic 3 Context: Control household doorway identity and access

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Make iOS the trustworthy control plane for physical household doorways: the
user can discover a Device without granting it access, approve and configure it
deliberately, preserve Profile isolation, and revoke access so a powered Device
cannot continue operating. The repository-local planning-artifacts directory
is absent; this context is therefore distilled from the canonical product hub
and its imported PRD, UX, architecture, and epic sources.

## Stories

- Story 3.1: Discover unconfigured Devices safely
- Story 3.2: Approve and configure a Device
- Story 3.3: Keep Wake Mappings unique and Profile-specific
- Story 3.4: Select one Device for a simultaneous wake
- Story 3.5: Fail closed for revoked or unavailable identities
- Story 3.6: Revoke access and require verified re-enrollment

## Requirements & Constraints

Physical Devices are either Pucks or Displays and are managed through iOS Settings. Discovery, approval, connection, Room assignment, Wake Mapping configuration, readiness, and revocation are distinct states. An unconfigured, pending, offline, failed, revoked, or identity-unverified Device remains inert: it cannot wake, capture audio, submit to Hermes, or silently fall back to another Profile.

Each Wake Mapping resolves to exactly one Hermes Profile; duplicates and ambiguous edits are rejected before publish. Each Device has an individually revocable credential. When multiple authorized Devices hear a mapping, the closest eligible Device wins and configured priority resolves an effective tie; losing Devices produce no acknowledgement, capture, or duplicate turn. Setup is not ready until Room, one or more valid Wake Mappings, and final ready confirmation are complete. Success must be visible on both iOS and the Device.

## Technical Decisions

Hermes remains authoritative for Profiles, agent context, sessions, and answer content. iOS owns physical-Device approval, Room assignment, Wake Mappings, per-Device credentials, revocation, and re-enrollment. Keep these concerns behind typed models and transport seams; views must not parse protocol frames or invent upload, device-administration, or server operations that Hermes or the Device transport has not exposed.

The discovery slice may establish deterministic fake-client contracts and local state projections, but must not guess the unresolved credential issuance, publication, offline last-known configuration, proximity signal, arbitration window, or re-enrollment protocol. Diagnostics remain opt-in and content-safe; credentials, prompts, response text, raw frames, audio, and device-specific secrets never enter source, tests, logs, or artifacts.

## UX & Interaction Patterns

Settings presents approved Devices separately from discovered Devices. `Add` opens discovery; selecting a candidate shows an explicit connecting state while the candidate remains visibly unconfigured and inert. Successful pairing is an explicit success state on iOS and the Device, not a silent list refresh. If LAN discovery is unavailable, QR/manual pairing identifies the same unconfigured candidate without granting access. Failures explain the next action and leave the candidate unapproved.

Later setup continues in the order `Room` → `Wake Mappings` → `Ready`. Pending or unverified changes are labeled pending, never ready. Device details make Disconnect consequential and explain the need for explicit re-enrollment. Labels are readable without relying on color, motion, or sound; core actions use accessible text and touch targets.

## Cross-Story Dependencies

Story 3.1 establishes the discovery/connection boundary consumed by approval and setup in Story 3.2. Stories 3.3–3.5 consume the approved Device, Profile, and Wake Mapping model; Story 3.4 additionally depends on a settled proximity/arbitration contract. Story 3.6 depends on credential revocation and re-enrollment semantics. Epic 1’s verified session/identity boundary is prerequisite context, while Device transport/firmware and any shared protocol changes remain external dependencies owned outside this iOS repository.
