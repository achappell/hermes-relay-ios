# Hermes Relay iOS

Native SwiftUI client foundation for Hermes voice sessions, with intentional
iOS and macOS targets. This is its own repository, intentionally separate from
the Python/Textual
[`hermes-relay-tui`](../hermes-relay-tui) client.

## Current state

The current voice slice provides:

- A SwiftUI conversation shell with connection, voice-state, and transcript
  surfaces.
- An in-app Configure Relay screen for endpoint and client metadata, with
  bearer-token entry backed by Keychain.
- Keychain-backed bearer-token storage and an application-support relay profile.
- One guarded automatic connection attempt on launch or foreground activation
  when a valid profile and token are already stored, with explicit setup and
  retry states.
- A protocol-v1 WebSocket transport gated on `hello_ack`, with normalized text,
  activity, audio, error, and completion events.
- Push-to-talk local transcription with permission and cancellation handling.
- Incremental signed 16-bit PCM playback with temporary WAV recovery when live
  playback fails.
- Content-safe microphone and inbound-playback activity signals with normalized
  levels, silence/noise/speech classification, throttling, and explicit safe
  unavailable states. These signals are the foundation for future opt-in
  hands-free barge-in; they do not enable hands-free mode by themselves.
- Opt-in, content-safe playback diagnostics for comparing stream arrival with
  first-buffer scheduling.
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
Tap the gear button to open Configure Relay. Enter the `ws://` or `wss://`
endpoint, client ID, device ID, display name, and bearer token, then choose
Save configuration. The token is stored in Keychain; the other fields are
stored in the application-support profile. When no configuration exists,
the app stays disconnected and displays setup guidance. When a valid profile
and token already exist, the app attempts one connection on launch or
foreground activation; a failed attempt remains visible and can be retried
with the Connect/Retry button.

To inspect playback timing in a Debug build, add
`--hermes-audio-debug` under the scheme's **Arguments Passed On Launch**. The
diagnostics record stream format, PCM byte counts, buffer scheduling, and
playback failures; they never record prompts, responses, tokens, raw frames, or
audio contents. For a booted iOS Simulator, view them with:

```bash
xcrun simctl spawn booted log stream \
  --info \
  --debug \
  --predicate 'subsystem == "com.achappell.HermesRelayIOS" && category == "audio-playback"'
```

The useful sequence is `audio chunk received` → `audio chunk scheduled` →
`audio first buffer scheduled`. If the first two appear while the relay is
still streaming, playback has started incrementally rather than waiting for
`audio_end`.

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

## GitHub Actions and releases

Pull requests and pushes to `main` run the Xcode build and XCTest checks on the
`macos-26` GitHub-hosted runner. CI builds and tests both the iOS Simulator and
macOS targets, and retains the XCTest result bundles for failed-run diagnosis.

Releases use Release Please and conventional commits. A push to `main` opens or
updates the release PR; merging that PR creates a `vX.Y.Z` tag and GitHub release,
then invokes the packaging workflow directly. The same workflow also accepts tag
pushes and manual dispatch for reruns. It reruns the macOS tests, builds the macOS
and iOS Simulator apps, and uploads unsigned archives with SHA-256 checksums.
These are internal development artifacts: physical iPhone distribution requires
a future Apple signing/TestFlight workflow.

The release version is kept in `version.txt` and mirrored in the Xcode project.
Do not put signing certificates, provisioning profiles, bearer tokens, or
Keychain values in Actions. A `RELEASE_PLEASE_TOKEN` repository secret is
optional; the workflow falls back to the repository's `GITHUB_TOKEN` and still
packages a newly created release in the same workflow run.

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
