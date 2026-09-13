# BMAD upstream context

Hermes Home product planning is canonical in a private product hub maintained
outside this public repository. Private hub paths and notes must not be copied
into public artifacts.

This repository is the downstream native Apple implementation. It owns the iOS/macOS presentation, local conversation state, secure credential storage, microphone permission, audio playback, and transport lifecycle. Hermes owns sessions, model routing, generation, speech generation, and the voice-session protocol.

## Before planning or building

1. Read the relevant upstream brief, PRD, epic, architecture, and UX notes
   from the private product hub available in the local working environment.
2. Read the shared coverage index for cross-repository applicability and
   dependencies. Treat it as context, not as a status tracker.
3. Use this repository's local story index, specification, validation record,
   and `sprint-status.yaml` for iOS scope and closure; do not publish private
   board URLs or personal planning notes.
4. Read this repository's `AGENTS.md`, then the local implementation docs in
   `docs/`.
5. Use the repository-local BMAD runtime for delivery work. Do not copy
   `_bmad/` or tool configuration from `hermes-relay-tui`.

## Traceability

Every substantive iOS item must reference a product outcome, have acceptance
criteria, a UX expectation, a validation scenario, and implementation evidence.
Keep the story identity, status, and local artifact links in
`_bmad-output/implementation-artifacts/story-index.yaml` and
`sprint-status.yaml`. Keep upstream IDs in local implementation artifacts
without publishing private board links. Product or shared-behaviour changes
discovered during delivery flow back to the private product hub; they do not
become a competing iOS PRD.

## Parallel work

`IOS-*` stories and local tickets belong here. TUI, Android, Home, and shared
Hermes protocol work belong in their owning repositories. One active slice is
allowed per repository/workstream, so independent iOS and TUI slices may both
be in `Building`. Shared contract or protocol work remains a prerequisite when
both clients depend on it.

Existing iOS architecture and workflow notes remain implementation-local. The
private product hub is the single home for durable cross-repository intent,
shared decisions, and reconciliation decisions. It is not the place to record
every local status transition.

## Current upstream baseline

The hub records the imported planning snapshot from the TUI planning history.
The current iOS conversation slice traces to FR-20 / Epic 5 / Story 5.1; use
the private hub for product intent and this repository's local index and
artifacts for the active slice rather than inferring status from an old
repository copy.
