# BMAD upstream context

Hermes Home product planning is canonical in the Personal Vault hub:

`~/Documents/Vaults/Personal Vault/projects/hermes-home/hermes-home.md`

This repository is the downstream native Apple implementation. It owns the iOS/macOS presentation, local conversation state, secure credential storage, microphone permission, audio playback, and transport lifecycle. Hermes owns sessions, model routing, generation, speech generation, and the voice-session protocol.

## Before planning or building

1. Read the Personal Vault hub and the linked upstream brief, PRD, epic, architecture, and UX notes relevant to the slice.
2. Inspect GitHub Project #3 for the card's priority, status, owner, dependencies, and current evidence:
   `https://github.com/users/achappell/projects/3/views/2`
3. Read this repository's `AGENTS.md`, then the local implementation docs in `docs/`.
4. Use the repository-local BMAD runtime for delivery work. Do not copy `_bmad/` or tool configuration from `hermes-relay-tui`.

## Traceability

Every substantive iOS item must have a Project #3 card with an outcome, acceptance criteria, UX expectation, validation scenario, and implementation evidence. Keep the upstream IDs in the card and in implementation artifacts. Product or shared-behaviour changes discovered during delivery flow back to the Personal Vault hub; they do not become a competing iOS PRD.

## Parallel work

`IOS-*` cards belong here; `TUI-*`/`HOME-*` cards belong in `hermes-relay-tui`; shared Hermes protocol work belongs in its owning repository. One active slice is allowed per repository/workstream, so independent iOS and TUI slices may both be in `Building`. Shared contract or protocol work remains a prerequisite when both clients depend on it.

Existing iOS architecture and workflow notes remain implementation-local. The Personal Vault is the single home for durable cross-repository product intent and reconciliation decisions.

## Current upstream baseline

The hub records the imported planning snapshot from `hermes-relay-tui` commit `e36e9b39d471f9e5e0e1c9e2e35b347b5ac7a9f2`. The current iOS conversation slice traces to FR-20 / Epic 5 / Story 5.1; use the hub and Project #3 for the active slice rather than inferring scope from an old repository copy.
