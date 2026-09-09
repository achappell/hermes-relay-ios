# Native Voice Interface Design

**Date:** 2026-08-30

**Status:** Draft for review

## Goal

Build a native voice conversation path for the Hermes Relay client that works
with the intentional iOS 26 and macOS 26 target matrix, while preserving the
existing Hermes voice-session protocol boundary and keeping remote operations
unsupported by the connected endpoint out of the client.

The first useful experience is push-to-talk: the user starts capture, sees a
local transcription, releases or cancels capture, sends the resulting text as
a normal Hermes turn, sees streamed response text, and hears streamed Hermes
audio.

## Existing context

The repository currently contains a SwiftUI conversation shell, a main-actor
`ConversationStore`, typed session models, and an unavailable
`HermesSessionClient`. The sibling TUI is the executable protocol reference.
The protocol currently supports:

- protocol-v1 `hello` followed by required `hello_ack`;
- protocol-v1 text `turn` messages with a unique `turn_id`, session ID, text,
  and `stt_source`;
- streamed text, status/activity, error, and completion events;
- `audio_start` metadata followed by binary signed 16-bit PCM frames; and
- `turn_end` completion.

The protocol does not expose client microphone upload, but Hermes endpoints may
advertise an explicit remote interrupt capability in `hello_ack`. The iOS/macOS
client performs local capture and transcription, sends recognized text through
the existing text turn contract, and uses a server-confirmed interrupt when
that capability is present. Endpoints without it retain the local
close-and-reconnect fallback and mark the submitted turn unconfirmed.

## Platform matrix

- Build targets intentionally support `iphoneos`, `iphonesimulator`, and
  `macosx`.
- The app uses iOS 26 and macOS 26 deployment targets.
- Shared domain, transport, and state code must compile on both platforms.
- Platform conditionals belong at capability edges: microphone permission,
  speech recognition, audio routing, entitlements, and minor toolbar/layout
  differences.
- The first hardware smoke path is iOS; macOS must still compile and receive a
  sandbox-capability validation path.
- iOS simulator tests cover deterministic state and failure behavior. They do
  not substitute for real microphone, speaker-route, interruption, or
  permission testing on hardware.

## Architecture

```text
SwiftUI views
    ↓ user intent / observed state
ConversationStore + VoiceSessionCoordinator (@MainActor)
    ├── SpeechInput protocol ── iOS/macOS speech adapter
    ├── AudioOutput protocol ── iOS/macOS PCM playback adapter
    └── HermesSessionClient ─── URLSessionWebSocketTask transport actor
                                    ↓ hello / turn frames
                              Hermes voice-session WebSocket
```

`ConversationStore` remains the source of truth for connection, transcript,
draft, and user-visible errors. A focused `VoiceSessionCoordinator` owns one
voice turn at a time and translates capture, recognition, transport, and
playback milestones into a single `VoiceState` value. Views render that state;
they do not infer it from transcript text or audio callbacks.

The transport owns JSON encoding/decoding, authentication headers, the
`hello`/`hello_ack` handshake, one WebSocket receive loop, and event
normalization. It never touches SwiftUI or audio APIs. Audio output consumes
typed PCM events and stays off the main actor.

## Domain and interfaces

`SessionModels.swift` should grow the typed values needed by the coordinator:

- `VoiceState`: `idle`, `listening`, `transcribing`, `thinking`, `speaking`,
  `buffering`, `complete`, `interrupted`, and `failed(String)`;
- `AudioFormat`: sample rate, channel count, and sample width;
- `SpeechInput` for authorization, start, partial/final recognition, and
  cancellation;
- `AudioOutput` for starting a format, accepting PCM chunks, ending a stream,
  stopping, and reporting a local playback failure; and
- normalized Hermes events for text append, text replacement, thinking/status,
  audio start/chunk/end, error, message completion, and turn completion.

The protocols must be `Sendable` and injectable. Production adapters may use
actors or task isolation, while tests use deterministic fakes. Raw JSON and
raw WebSocket frames must not cross into the store or views.

## Data flow

1. The configuration store supplies an endpoint and bearer token without
   exposing the token to logs or transcript state.
2. The transport opens one WebSocket, sends `hello`, waits for `hello_ack`,
   and reports a confirmed connected state only after the acknowledgement.
3. Push-to-talk requests microphone and speech authorization, then starts the
   speech adapter. Partial recognition updates the voice surface, not the
   committed transcript.
4. Release finalizes the recognized text. Cancel stops local capture and
   discards the unsubmitted recognition without losing any pre-existing draft.
5. A non-empty final recognition becomes one user transcript record and one
   text `turn` with `stt_source=local`.
6. The coordinator maps transport activity to `thinking`, text events to the
   active assistant message, and audio events to the playback adapter.
7. `audio_start` begins playback with its declared signed-16-bit PCM format;
   binary chunks are queued or played; `audio_end` closes that response stream.
8. When `hello_ack.capabilities` contains `interrupt`, an active voice turn
   sends one protocol-v1 `interrupt`. `audio_abort` stops playback and clears
   pending audio immediately; `turn_interrupted` confirms the remote turn is
   over without reconnecting or creating a replacement turn.
9. `turn_end` settles the coordinator on `complete` only after any described
   audio has drained. Missing or failed audio preserves the text and reports
   that playback is unavailable; errors preserve the last safe transcript/draft
   state and explain the next action.

## Interaction and failure rules

- The primary control is push-to-talk. Always-listening and wake-word behavior
  are outside this design.
- A cancelled capture must return to a ready state without submitting a turn,
  losing the draft, or leaving a capture task running.
- A denied microphone or speech permission must name the permission and give a
  next action; it must not look like a relay failure.
- An unavailable speaker may buffer a recoverable WAV response or report that
  playback failed while keeping the text response visible.
- A disconnected session is never shown as connected and must not silently
  replay a turn that may already have reached Hermes.
- Unknown protocol events may produce opt-in, content-safe diagnostics, but
  raw payloads, prompts, responses, tokens, and audio contents must not be
  logged.
- A local capture cancellation stops capture without submitting a turn. Tapping
  the voice control during a response requests a server-confirmed interrupt
  when the endpoint advertises it; `audio_abort` stops playback immediately.
  If the endpoint cannot confirm interruption, the client closes and
  reconnects, labels the submitted turn unconfirmed, and never replays it.

## Planned slices

All new iOS slices remain in `Inbox` until IOS-01 is validated and moved out of
`Building`. Only one slice becomes active at a time.

### IOS-01 — Foundation and platform validation

Keep the existing slice active. Update its documentation and smoke plan to
match the intentional iOS 26/macOS 26 matrix, then validate both target
families. Do not add voice behavior to this slice.

**Acceptance:** The app and test targets build with the declared platform
matrix, the shell remains honest about unavailable transport, and the manual
smoke plan records the platform-specific validation result.

### IOS-02 — Secure configuration and capability setup

Add Keychain-backed endpoint/token storage, configuration state, generated
privacy strings, and the iOS/macOS audio/network capability declarations.

**Acceptance:** Missing, malformed, and stored profiles have explicit states;
credentials never enter logs or source; microphone permission prompts are
platform-correct; and both targets compile with their required capabilities.

**Validation:** Keychain fake tests, redacted diagnostics tests, permission
failure tests, and a signed macOS sandbox build check.

### IOS-03 — WebSocket handshake and typed text turn

Replace the unavailable client with a URLSession WebSocket transport using the
existing Hermes contract. Implement one reader task, bearer authentication,
hello acknowledgement gating, typed turn IDs, event normalization, close/error
handling, and injection into `ConversationStore`.

**Acceptance:** A fake server can drive connect → `hello_ack` → text turn →
streamed text → `turn_end`; malformed or unexpected frames fail safely; and
the shell renders a real typed turn without parsing raw protocol data.

**Validation:** Focused fake-WebSocket contract tests, simulator build/test,
and a manual live typed-turn smoke test with a locally supplied credential.

### VOICE-04 — Push-to-talk and local transcription

Add the speech-input protocol and platform adapters using microphone capture
and Apple's Speech framework. Model authorization, listening, partial
transcription, final transcription, cancellation, and capture failure.

**Acceptance:** Start/release submits exactly one recognized text turn; start/
cancel submits none; partial text stays provisional; permission denial is
actionable; and cancelled capture leaves existing draft text intact.

**Validation:** Deterministic speech fakes for every state transition, iOS
device smoke test with permission grant/deny, and macOS compile/sandbox check.

### VOICE-05 — Streamed PCM playback and fallback

Add the audio-output protocol and platform adapters for signed 16-bit PCM,
including format validation, buffering, route changes, stop/close cleanup, and
WAV fallback when live playback cannot start or fails mid-stream.

**Acceptance:** `audio_start` configures the declared format, binary chunks are
played in order, `audio_end` closes the stream, unsupported formats fail
actionably, and text remains available when playback fails.

**Validation:** Fake-output tests for chunk ordering and cleanup, malformed
format tests, simulator fallback tests, and iOS hardware speaker/route smoke
testing.

### VOICE-06 — Voice coordinator and lifecycle surface

Integrate input, transport, transcript, and output into one coordinator and add
a calm dedicated voice indicator for idle, listening, transcribing, thinking,
speaking, buffering, complete, interrupted, and failed states.

**Acceptance:** The interface has one obvious voice control, state transitions
are legible without transcript noise, cancellation never strands a task, and a
completed response has one stable assistant boundary with no duplicate text.

**Validation:** State-machine tests, fake end-to-end event sequences, UI tests
for control availability and failure wording, and a device walkthrough of
idle → listening → cancelled → ready plus idle → response → complete or
playback failure.

### IOS-07 — Recovery and local continuity

Harden disconnect/reconnect behavior, preserve drafts and local conversation
state across relaunch, and document the boundary where server-confirmed
session hydration will later connect to `SESSION-01`.

**Acceptance:** Offline, reconnect, app relaunch, and interrupted-audio paths
remain understandable; ambiguous remote turns are not replayed; and local
state does not claim server confirmation.

**Validation:** Deterministic transport failure tests, relaunch persistence
tests, and device smoke tests for network loss and audio interruption.

### IOS-26 — Server-confirmed interruption and playback abort

Adopt Hermes' advertised `interrupt` capability for active voice responses.
Send one protocol-v1 interrupt, stop queued playback on `audio_abort`, and
retain the partial transcript when `turn_interrupted` confirms cancellation.
Keep the close-and-reconnect fallback for legacy endpoints and label those
turns unconfirmed.

**Acceptance:** A supported endpoint interrupts without disconnecting or
creating a replacement turn; stale text, audio, and completion frames cannot
contaminate the next turn; and a legacy endpoint remains recoverable and
honest about confirmation.

**Validation:** Deterministic supported, nested-capability, timeout/fallback,
late-frame, audio-abort, and coordinator tests, followed by an iOS device
smoke test during streamed playback.

## Explicitly out of scope

- Streaming microphone bytes to Hermes before the relay exposes an upload
  contract.
- Remote steer, approval, sudo, and secret-prompt operations; track these under
  `RELAY-01`. Remote interruption is implemented by IOS-26 only for the
  advertised Hermes contract.
- Session browser and server transcript hydration; track these under
  `SESSION-01`.
- Wake-word/always-listening behavior.
- Terminal-only commands, attachment handling, usage, compression, and other
  TUI controls.

## Definition of voice MVP

On a real iOS device, a configured user can connect, press and hold the voice
control, see listening and local transcription states, release to submit one
text-backed Hermes turn, see streamed response text, hear streamed PCM audio,
cancel a later capture without submitting it, and recover from denied
microphone access or unavailable playback without losing the visible response.
