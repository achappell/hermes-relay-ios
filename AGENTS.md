# Codex Profile

This repository is the native SwiftUI client for Hermes voice sessions, with
intentional iOS and macOS targets. It is a separate product repository from
`hermes-relay-tui`; keep the two repositories independently buildable and do
not copy terminal-specific UI assumptions into the Apple client.

## Task management — local BMad mode

Amanda has explicitly paused GitHub Project #3 while the local BMad surface
reconciliation is completed. Until she explicitly reopens the board, do not
inspect, query, create, edit, move, delete, or reconcile Project #3 items.

The shared surface coverage index (kept at the historical
[`../hermes-relay-tui/_bmad-output/implementation-artifacts/surface-coverage-matrix.md`](../hermes-relay-tui/_bmad-output/implementation-artifacts/surface-coverage-matrix.md)
path) is a thin cross-repository view of applicability, evidence, and shared
dependencies. Read it before answering "what's next" or beginning substantive
story work. It is not a backlog, story specification, or formal status
authority; this repository's local story artifacts own iOS delivery scope and
closure, and the Personal Vault owns durable product intent.

While the board is paused:

- Keep one active slice per iOS workstream and use this repository's local
  BMad artifacts to record its scope, acceptance criteria, validation, and
  status.
- Finish an `In review` slice whose build or validation gate is close and that
  unlocks later stories before opening a new slice.
- Then choose an open story with the strongest useful coverage across incomplete
  surfaces and settled prerequisites, keeping the work a small, verifiable
  vertical slice.
- Treat `Implemented`, `In review`, `Foundation`, `Open`, and `N/A` in the
  shared index as evidence or applicability labels only. Use the local iOS
  story specification, context, validation record, and review state for formal
  status and closure. Never mark an iOS story complete because another surface
  is complete.
- Follow the surface story ID from the index to the shared surface-specific
  map in `../hermes-relay-tui/_bmad-output/planning-artifacts/epics.md` and
  then to the owning iOS artifact. Do not duplicate acceptance criteria or
  create a second cross-repository matrix in this repository.
- Do not create a duplicate backlog in `docs/plans/`; select from the existing
  BMad epic/story set and record prioritization decisions in local artifacts.

When Amanda explicitly reopens board work, restore the Project #3 procedure
before choosing a board-scoped task: verify the credential with `gh auth
status`, inspect the board, and reconcile it with the matrix and local
artifacts. Never print token values.

## Product planning authority

Durable Hermes Home product intent and cross-repository reconciliation are
canonical in the Personal Vault hub:

`~/Documents/Vaults/Personal Vault/projects/hermes-home/hermes-home.md`

Read the hub and its relevant source notes before using BMAD for a new slice.
While GitHub Project work is paused, use the surface coverage index for
cross-repository applicability, evidence, and dependencies, and use this
repository's local BMAD runtime and artifacts for iOS delivery scope, status,
and validation. The shared surface-specific story identities live in
`hermes-relay-tui/_bmad-output/planning-artifacts/epics.md`; do not copy them
into a second local epic map. Do not copy `_bmad/` or tool configuration from
`hermes-relay-tui`, and do not create a second matrix or product PRD. Existing
local architecture and workflow notes remain implementation context. See
[`docs/bmad-upstream.md`](docs/bmad-upstream.md).

Product or shared-behaviour decisions discovered during implementation flow
back to the hub. `IOS-*` cards belong here; `TUI-*`/`HOME-*` cards belong in
`hermes-relay-tui`.

## Product boundary

The iOS/macOS app owns presentation, local conversation state, secure
credential storage, microphone permission, audio playback, and transport
lifecycle. Hermes owns sessions, model routing, generation, speech generation,
and the voice-session protocol.

The current protocol facts come from the sibling TUI:

- Connection begins with a protocol-v1 `hello` message and requires
  `hello_ack`.
- Text turns use a protocol-v1 `turn` message and stream normalized text,
  activity, audio, error, and completion events.
- Binary WebSocket frames are signed 16-bit PCM audio after `audio_start`
  describes the stream.
- A relay may advertise the protocol-v1 `interrupt` capability. When it does,
  the iOS client may send one interrupt for the active turn and consume
  `audio_abort`/`turn_interrupted`; legacy or unconfirmed interruption falls
  back to bounded close/reconnect and marks the turn unconfirmed.
- The iOS client must not invent upload, remote undo, usage, compression, or
  other server operations before Hermes exposes them.

## Security

- Never commit bearer tokens, profile files, audio, signing certificates, or
  device-specific credentials.
- Use Keychain-backed storage for any future token/profile UI.
- Do not log prompts, response text, tokens, or audio contents.
- Keep protocol diagnostics opt-in and content-safe.

## Development

Use the repository's Xcode project and the supported local toolchain. The
baseline is Swift 6.3 with Xcode 26.6, iOS 26, and macOS 26 deployment targets.

Before handing off a change:

1. Run the focused XCTest target.
2. Build and test the iOS simulator target with `xcodebuild`.
3. Build the macOS target with `xcodebuild`.
4. Run the manual smoke plan for the current slice.
5. Review the diff for credentials, audio captures, generated build files, and
   unrelated repository edits.

Tests should use fake clients and deterministic events. Do not require a live
Hermes endpoint for unit tests.
