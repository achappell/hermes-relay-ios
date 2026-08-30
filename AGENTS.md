# Codex Profile

This repository is the native iOS client for Hermes voice sessions. It is a
separate product repository from `hermes-relay-tui`; keep the two repositories
independently buildable and do not copy terminal-specific UI assumptions into
the mobile app.

## Task management

GitHub Project #3 is the task queue:

https://github.com/users/achappell/projects/3/views/2

IOS-01 is the current vertical slice. Keep one iOS slice active at a time and
move it through `Inbox` → `Ready` → `Building` → `Verify` → `Done`. Keep the
built-in status aligned: `Todo` for planned work, `In Progress` for active or
verification work, and `Done` only after validation and merge.

Every substantive change needs a project item with an outcome, acceptance
criteria, UX expectation, and validation scenario. Record implementation and
validation evidence on the item. Split follow-ups instead of expanding one
slice into a grab bag.

## Product boundary

The iOS app owns presentation, local conversation state, secure credential
storage, microphone permission, audio playback, and transport lifecycle. Hermes
owns sessions, model routing, generation, speech generation, and the voice
session protocol.

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
baseline is Swift 6.3 with Xcode 26.6 and iOS 17 as the minimum deployment
target.

Before handing off a change:

1. Run the focused XCTest target.
2. Build and test the iOS simulator target with `xcodebuild`.
3. Run the manual smoke plan for the current slice.
4. Review the diff for credentials, audio captures, generated build files, and
   unrelated repository edits.

Tests should use fake clients and deterministic events. Do not require a live
Hermes endpoint for unit tests.
