# iOS Voice Interface Testing Plan

This plan validates the native voice path without recording credentials,
prompts, responses, microphone captures, PCM bytes, or other private content.
Use a locally configured relay profile and Keychain token. Do not paste either
value into this file, a ticket, a test fixture, a screenshot, or a log.

## Automated validation

Run from the repository root with Xcode 26.6 or newer:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Run the focused deterministic suites on macOS with signing disabled for the
local test runner:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY='' \
  test \
  -only-testing:HermesRelayIOSTests/ConversationStoreTransportTests \
  -only-testing:HermesRelayIOSTests/SpeechInputTests \
  -only-testing:HermesRelayIOSTests/AudioOutputTests \
  -only-testing:HermesRelayIOSTests/VoiceSessionCoordinatorTests \
  -only-testing:HermesRelayIOSTests/ConversationPersistenceTests \
  -only-testing:HermesRelayIOSTests/RecoveryTests
```

Run the complete test target on an installed iOS simulator runtime and record
the destination used:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'platform=iOS Simulator,name=<installed iPhone>' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

If the simulator test runner cannot launch or install, record that as an
environment limitation; retain the successful simulator build and deterministic
macOS test evidence. Do not claim hardware behavior from a simulator build.

## iOS device walkthrough

Record only pass/fail, state transitions, turn counts, error wording, and the
device/OS used.

1. Launch with no local profile or token. Confirm Connect remains disconnected
   and shows configuration guidance rather than a connected state.
2. Provision the relay endpoint locally and the bearer token in Keychain. Keep
   both values out of screenshots and logs. Confirm connection reaches Connected
   only after Hermes sends `hello_ack`.
3. Grant microphone and speech-recognition permissions. Press and hold Voice
   control. Confirm `Ready → Listening → Transcribing` and provisional text
   appear outside the committed transcript.
4. Release after a non-empty recognition. Confirm exactly one user turn, one
   streamed assistant boundary, and `Thinking → Buffering/Speaking → Ready`.
   Confirm the response audio is heard when the device speaker route is valid.
5. Start a later capture, then use Cancel. Confirm no turn is submitted, the
   provisional text is cleared, and any existing draft remains unchanged.
6. Deny microphone or speech permission. Confirm the failure names the local
   permission and directs the user to Settings; it must not look like a relay
   failure.
7. Exercise an unavailable or interrupted speaker route. Confirm response text
   remains visible and the UI reports playback failure or fallback recovery.
8. Drop the network during a turn. Confirm the connection is not shown as
   connected, the local turn is marked unconfirmed, reconnect does not replay
   it, and a later explicitly submitted turn can complete.
9. Review diagnostics and artifacts. Confirm no prompt, response, token, raw
   frame, microphone audio, or PCM content was logged or captured.

## macOS validation

Build the shared target explicitly:

```bash
xcodebuild \
  -project HermesRelayIOS.xcodeproj \
  -scheme HermesRelayIOS \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Confirm the build settings include macOS 26, the `macosx` supported platform,
the sandbox entitlement file, and outgoing network access:

```bash
xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS \
  -destination 'platform=macOS,arch=arm64' -showBuildSettings \
  | rg 'MACOSX_DEPLOYMENT_TARGET|SUPPORTED_PLATFORMS|CODE_SIGN_ENTITLEMENTS|ENABLE_APP_SANDBOX|com.apple.security.network.client'
```

Launch the app once with no profile/token and confirm the shared shell remains
honest about unavailable relay configuration. macOS compile and sandbox checks
do not substitute for iOS microphone, permission, speaker-route, or device
network testing.

## Evidence record

```text
Date/time:
Commit:
iOS simulator build:
Focused XCTest suites:
Complete XCTest destination/result:
iOS device/OS:
Device walkthrough result:
macOS build/sandbox result:
Known environment limitations:
Private-content review:
```
