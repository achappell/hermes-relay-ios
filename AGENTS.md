# Codex Profile

This repository is the native SwiftUI client for Hermes voice sessions, with
intentional iOS and macOS targets. It is a separate product repository from
`hermes-relay-tui`; keep the two repositories independently buildable and do
not copy terminal-specific UI assumptions into the Apple client.

## Task management — local BMad mode

The maintainer has paused external board reconciliation while the local BMad
surface work is completed. Until the board is explicitly reopened, do not
inspect, query, create, edit, move, delete, or reconcile external board items.

The shared surface coverage index (kept at the historical
[`../hermes-relay-tui/_bmad-output/implementation-artifacts/surface-coverage-matrix.md`](../hermes-relay-tui/_bmad-output/implementation-artifacts/surface-coverage-matrix.md)
path) is a thin cross-repository view of applicability, evidence, and shared
dependencies. Read it before answering "what's next" or beginning substantive
story work. It is not a backlog, story specification, or formal status
authority; this repository's local story artifacts own iOS delivery scope and
closure, and the canonical product hub outside this repository owns durable
product intent.

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
- For an existing imported story identity, use the shared surface map as
  context, then follow this repository's `story-index.yaml` to the owning
  artifact. New iOS stories are added to the local index and local tracker;
  they do not require an edit to the TUI repository.
- Do not duplicate acceptance criteria or create a second cross-repository
  matrix in this repository. The local `story-index.yaml` is the iOS story
  map, and `sprint-status.yaml` is the iOS delivery-status authority.
- Do not create a backlog in `docs/plans/`; record iOS prioritization in the
  local story index and tracker.

When the maintainer explicitly reopens board work, restore the external-board
procedure before choosing a board-scoped task: verify the credential with `gh
auth status`, inspect the board, and reconcile it with the matrix and local
artifacts. Never print token values.

## Product planning authority

Durable Hermes Home product intent and cross-repository reconciliation are
canonical in the product hub maintained outside this repository. Read the hub
and its relevant source notes from the local working environment before using
BMAD for a new slice. Do not copy private hub paths or personal notes into this
public repository.
While GitHub Project work is paused, use the surface coverage index for
cross-repository applicability, evidence, and dependencies, and use this
repository's local BMAD runtime and artifacts for iOS story scope, status, and
validation. The TUI epic map is an imported compatibility snapshot, not the
iOS story or status authority. Do not copy `_bmad/` or tool configuration from
`hermes-relay-tui`, and do not create a second cross-repository matrix or
product PRD. Existing local architecture and workflow notes remain
implementation context. See
[`docs/bmad-upstream.md`](docs/bmad-upstream.md).

Product or shared-behaviour decisions discovered during implementation flow
back to the product hub. `IOS-*` records belong here; TUI, Android, Home, and
other surface records belong in their owning repositories.

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

## Worktrees

All linked feature and agent worktrees for this repository belong under
`.worktrees/<name>` inside the repository's main checkout. Keep `.worktrees/`
ignored and do not create sibling `*-worktrees` directories or use a global
tool-specific worktree location. BMAD loop-managed run worktrees under
`.bmad-loop/runs/<run>/worktrees/` are engine-owned and remain there.

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
