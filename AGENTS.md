# Codex Profile

This repository is the native SwiftUI client for Hermes voice sessions, with
intentional iOS and macOS targets. It is a separate product repository from
`hermes-relay-tui`; keep the two repositories independently buildable and do
not copy terminal-specific UI assumptions into the Apple client.

## Task management

GitHub Project #3 is the task queue:

https://github.com/users/achappell/projects/3/views/2

The board determines the active iOS slice; `IOS-01` is the completed
foundation baseline. Keep one active slice per iOS workstream and move it
through `Inbox` → `Ready` → `Building` → `Verify` → `Done`. The iOS and TUI
repositories may have independent cards in `Building` at the same time;
shared contract or protocol work remains a prerequisite when both clients
depend on it. Keep the built-in status aligned: `Todo` for planned work,
`In Progress` for active or verification work, and `Done` only after validation
and merge.

Every substantive change needs a project item with an outcome, acceptance
criteria, UX expectation, and validation scenario. Record implementation and
validation evidence on the item. Split follow-ups instead of expanding one
slice into a grab bag.

## Product planning authority

Durable Hermes Home product intent and cross-repository reconciliation are
canonical in the Personal Vault hub:

`~/Documents/Vaults/Personal Vault/projects/hermes-home/hermes-home.md`

Read the hub and its relevant source notes before using BMAD for a new slice.
Use GitHub Project #3 for actionable scope, priority, ownership, dependencies,
and workflow state. Use this repository's local BMAD runtime for delivery; do
not copy `_bmad/` or tool configuration from `hermes-relay-tui`. Existing local
architecture and workflow notes remain implementation context, not a second
product PRD. See [`docs/bmad-upstream.md`](docs/bmad-upstream.md).

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
- The protocol currently has no explicit remote interrupt operation.
- The iOS client must not invent upload, remote undo, usage, compression, or
  server-side interruption operations before Hermes exposes them.

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
