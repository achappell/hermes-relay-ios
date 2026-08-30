# Hermes Relay iOS

Native SwiftUI client foundation for Hermes voice sessions, with intentional
iOS and macOS targets. This is its own repository, intentionally separate from
the Python/Textual
[`hermes-relay-tui`](../hermes-relay-tui) client.

## Current state

The current voice slice provides:

- A SwiftUI conversation shell with connection, voice-state, and transcript
  surfaces.
- Keychain-backed bearer-token storage and an application-support relay profile.
- A protocol-v1 WebSocket transport gated on `hello_ack`, with normalized text,
  activity, audio, error, and completion events.
- Push-to-talk local transcription with permission and cancellation handling.
- Signed 16-bit PCM playback with temporary WAV recovery when live playback
  fails.
- Local transcript/draft persistence and an explicit unconfirmed-turn marker;
  reconnect never silently replays a turn.
- Deterministic XCTest coverage for transport, speech, audio, coordination, and
  recovery boundaries.

## Requirements

- macOS with Xcode 26.6 or newer
- Swift 6.3 or newer
- iOS 26 or newer for the iOS target
- macOS 26 or newer for the macOS target
- An Hermes voice-session endpoint and bearer token for future live testing

No live endpoint or token is required to build the foundation or run unit
tests.

## Open the app

```bash
open HermesRelayIOS.xcodeproj
```

Select the `HermesRelayIOS` scheme and either an iPhone simulator or `My Mac`.
Without a locally stored profile and Keychain token, Connect displays an
actionable configuration message and never claims a relay connection.

## Command-line validation

Build for a generic simulator without signing:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the unit tests on an installed simulator runtime:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

If the named simulator is unavailable, choose an installed iPhone simulator
in Xcode and use its name in the command.

Build the macOS target explicitly:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

When a destination is omitted, Xcode may select macOS because the application
intentionally supports `iphoneos`, `iphonesimulator`, and `macosx`.

## Hermes protocol facts

The sibling TUI is the current executable reference for the voice-session
channel. The iOS client should preserve these boundaries:

1. Send `hello` with protocol version, client/device identity, and session ID.
2. Require `hello_ack` before treating the session as connected.
3. Send text turns with a unique `turn_id`, session ID, text, and STT source.
4. Normalize streamed text, thinking/activity, audio, error, and completion
   events into typed app events.
5. Keep WebSocket reading in one transport task and deliver events to the
   main-actor store.
6. Capture and transcribe locally; do not upload microphone bytes to Hermes.
7. Play only the declared signed 16-bit PCM stream and preserve visible text
   if playback fails.

The existing relay is text-capable but does not currently expose a complete
iOS-specific upload or control contract. Do not silently drop attachments or
claim that unsupported remote operations worked.

## Workflow

Read [`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md),
and [`docs/workflow.md`](docs/workflow.md) before extending the foundation.
The active plan is [`docs/plans/2026-08-30-ios-01-foundation-plan.md`](docs/plans/2026-08-30-ios-01-foundation-plan.md).

Project work is tracked on [GitHub Project #3](https://github.com/users/achappell/projects/3/views/2),
with IOS-01 as the current slice.
