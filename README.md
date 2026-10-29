# Hermes Relay iOS

Native SwiftUI client foundation for Hermes voice sessions, with intentional
iOS and macOS targets. This is its own repository, intentionally separate from
the Python/Textual
[`hermes-relay-tui`](../hermes-relay-tui) client.

## Current state

The current voice slice provides:

- A SwiftUI ambient HUD with minimal connection/session status, an
  audio-reactive visualizer, a readable recent-transcript rail with live
  follow/pause behavior, and an intentional full transcript history sheet.
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
- Optional word-timed transcript reveal when the relay sends `speech_timing`
  events. The rail follows the actual audio playback position and uses the
  received PCM/WAV duration for an overall-cadence fallback when word timing
  metadata is absent or invalid.
- Content-safe microphone and inbound-playback activity signals with normalized
  levels, silence/noise/speech classification, throttling, and explicit safe
  unavailable states. On iOS, the user may explicitly arm hands-free mode;
  speech boundaries submit one turn at a time and never arm at launch;
  background noise cannot end an active capture, and Hermes playback cannot
  wake a follow-up turn.
- Server-confirmed interruption for relays that advertise the `interrupt`
  capability. The voice control sends one protocol-v1 interrupt for the active
  turn, stops queued playback on `audio_abort`, and waits for
  `turn_interrupted`; endpoints without that capability use the existing
  close-and-reconnect path and keep the submitted turn marked unconfirmed.
- The HUD consumes those activity signals to show live state and transcript
  transitions. The recent transcript rail follows streaming text until the
  user reads backward, then offers an explicit resume-live action. Hands-free
  mode remains visibly armed across response phases, but automatic barge-in is
  enabled only on an echo-safe headphone route; the built-in speaker stays
  protected from self-triggering. Push-to-talk remains available as the
  explicit capture path when hands-free is disarmed.
- Opt-in, content-safe playback diagnostics for comparing stream arrival with
  first-buffer scheduling.
- Local transcript/draft persistence and an explicit unconfirmed-turn marker;
  reconnect never silently replays a turn.
- Deterministic XCTest coverage for transport, speech, audio, coordination, and
  recovery boundaries.

## Requirements

- macOS with Xcode 27 or newer
- Swift 6.3 or newer
- iOS 26 or newer for the iOS target
- macOS 26 or newer for the macOS target
- For direct Standard mode: an unmodified Hermes native session server supporting
  the canonical `/api/ws` session authority (verified at upstream commit
  `83bde48a4d9760d84220a9b29094a1ad86410f6e`), a WSS endpoint and its Standard token

No live endpoint or credential is required to build or run unit tests.

## Open the app

```bash
open "Hermes Relay.xcodeproj"
```

Select the `HermesRelay` scheme and either an iPhone simulator or `My Mac`.
Open **Connection settings** with the gear button. New setup offers
**HomeBridge** (Home enrollment) or **Standard Hermes** (direct connection).
Standard takes a `wss://host/api/ws` endpoint, a Standard token, and an optional
Hermes target profile (blank means `default`). It does not ask for a Home
pairing code or fork client/device IDs. An authenticated, non-creating
readiness check must succeed before saving. Older servers without the
supported native session authority are reported unsupported, not retried
through the legacy relay.

The selected mode stays visible. Existing HomeBridge and Legacy profiles
remain available; an outage never switches mode or suggests a fallback.
Standard credentials use a separate Keychain service, not Home or Legacy
credentials. Do not put credentials in endpoint URLs. Changing an endpoint
requires a newly entered token and saves a new connection identity; the
earlier connection, credential and local history remain intact.

Direct Standard currently supports **typed streaming only**. Microphone,
hands-free and audio controls are unavailable with an explanation. Home
pairing, approvals, room/device administration and Home diagnostics controls
are not Standard features. Home diagnostics uploads are paused while
Standard is active; existing Home consent is preserved.

Use **New conversation** deliberately to start another remote session.
Reconnect/relaunch resumes only a verified durable reference, without
resending local messages. If continuity is unavailable, the app explains
that and requires New conversation; failed New never silently replaces
the old session. **Leave this conversation** sends no prompt or interrupt,
keeps its transcript, and releases the local recovery guard. Active or
uncertain turns otherwise block connection changes. Standard closes on
background and marks in-flight delivery uncertain. If Leave cannot be saved,
the recovery guard stays in place: retry Leave or complete a successful New
conversation before changing connections.

Standard transcript/draft files are scoped by local connection, mode,
endpoint and Hermes target profile; credentials never enter those files.
New identities never import another connection's transcript or session.
Select an earlier saved connection to view its retained local history.
Deleting a connection removes its own credential and history only.

Older app builds can safely load the connection collection without treating
Standard as Legacy, but **saving settings in an older build drops Standard
entries it does not understand**. Do not edit/save connection settings after
downgrading; keep a recoverable configuration copy before a downgrade.

To inspect playback timing in a Debug build, add
`--hermes-audio-debug` under the scheme's **Arguments Passed On Launch**. The
diagnostics record stream format, PCM byte counts, buffer scheduling, and
playback failures; they never record prompts, responses, tokens, raw frames, or
audio contents. For a booted iOS Simulator, view them with:

```bash
xcrun simctl spawn booted log stream \
  --info \
  --debug \
  --predicate 'subsystem == "com.achappell.HermesRelay" && category == "audio-playback"'
```

The useful sequence is `audio chunk received` → `audio chunk scheduled` →
`audio first buffer scheduled`. If the first two appear while the relay is
still streaming, playback has started incrementally rather than waiting for
`audio_end`.

## Command-line validation

Build for a generic simulator without signing:

```bash
xcodebuild \
  -project "Hermes Relay.xcodeproj" \
  -scheme HermesRelay \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the unit tests on an installed simulator runtime:

```bash
xcodebuild \
  -project "Hermes Relay.xcodeproj" \
  -scheme HermesRelay \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

If the named simulator is unavailable, choose an installed iPhone simulator
in Xcode and use its name in the command.

Build the macOS target explicitly:

```bash
xcodebuild \
  -project "Hermes Relay.xcodeproj" \
  -scheme HermesRelay \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

When a destination is omitted, Xcode may select macOS because the application
intentionally supports `iphoneos`, `iphonesimulator`, and `macosx`.

## GitHub Actions and releases

GitHub Actions CI runs on pull requests targeting `main`, pushes to `main`, or
an intentional manual dispatch. It builds and tests both Apple targets on a
macOS runner.

Releases use Release Please and conventional commits. A push to `main` opens or
updates the release PR; merging that PR creates a `vX.Y.Z` tag and GitHub release,
then invokes the packaging workflow directly. The same workflow also accepts tag
pushes and manual dispatch for reruns. It reruns the macOS tests, builds the macOS
and iOS Simulator apps, and uploads unsigned archives with SHA-256 checksums.
These are internal development artifacts; physical iPhone distribution is
handled by the separate TestFlight workflow below.

The [`TestFlight` workflow](.github/workflows/testflight.yml) supports both a
manual run and automatic submission after the release packaging workflow
finishes. Configure its App Store Connect API key, distribution certificate,
and protected GitHub environment as described in
[`docs/testflight.md`](docs/testflight.md); no Hermes endpoint or bearer token
is required by the pipeline.

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
8. A relay may advertise `interrupt` in `hello_ack.capabilities`. For an
   active turn, the client may send a protocol-v1 `interrupt` with the turn
   and session IDs. `audio_abort` stops local playback immediately, and
   `turn_interrupted` confirms the server-side cancellation. If the capability
   is absent or confirmation times out, the client falls back to closing and
   reconnecting; it labels the submitted turn unconfirmed and never replays it
   automatically.
9. A relay that supports word-timed captions may send this optional event:

   ```json
   {
     "type": "speech_timing",
     "payload": {
       "segment_id": "segment-1",
       "text": "Hermes keeps moving.",
       "words": [
         {"text": "Hermes", "start_ms": 0, "end_ms": 280},
         {"text": "keeps", "start_ms": 280, "end_ms": 510},
         {"text": "moving.", "start_ms": 510, "end_ms": 920}
       ]
     }
   }
   ```

   Word offsets are relative to the beginning of the active inbound audio
   stream. Reusing a `segment_id` revises that segment; omitted or malformed
   timing must never hide the response text.

Hermes can optionally emit this timing extension when the experimental
provider-side forced aligner is enabled. The client still uses the received
PCM/WAV duration as a safe fallback when alignment is disabled, unavailable, or
invalid; an endpoint that only sends text and PCM does not provide exact word
and pause synchronization.

## Workflow

Read [`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md),
and [`docs/workflow.md`](docs/workflow.md) before extending the foundation.
The active plan is [`docs/plans/2026-08-30-ios-01-foundation-plan.md`](docs/plans/2026-08-30-ios-01-foundation-plan.md).

Project work is tracked in the repository's local BMad artifacts, with IOS-01
as the current slice. Private board links and product-hub paths are kept out
of this public repository.
