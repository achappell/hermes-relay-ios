# Architecture

## Initial boundaries

```text
SwiftUI views
    ↓ user intent / observed state
ConversationStore + VoiceSessionCoordinator (@MainActor)
    ├── SpeechInput / AudioOutput platform adapters
    └── HermesSessionClient transport seam
            ↓ hello / turn frames
        Hermes voice-session WebSocket
```

The first repository commit stops at the transport seam. The UI can render a
conversation and an honest unavailable state, while tests can exercise the
store without a network connection.

## Planned modules

### App and presentation

- `HermesRelayIOSApp.swift` owns the application entry point.
- `Views/` owns SwiftUI layout and interaction.
- `Views/AmbientHUD.swift` owns the ambient presentation projection, activity
  snapshot subscription, state visualizer, and transcript history sheet.
  `Views/RecentTranscriptRail.swift` owns the bounded recent transcript
  projection and its local follow/pause state: streaming updates stay anchored
  to the newest entry until the user reads backward, then an explicit resume
  action reattaches the live anchor. `AmbientHUDModel` is a small main-actor
  adapter over the actor-isolated `AudioActivityStore`.
- `ViewModels/ConversationStore.swift` owns main-actor conversation state and
  turns typed client events into transcript records.
- `ConversationStore.sessionStartedAt` records the current confirmed
  connection start for the HUD session-duration label; it is cleared on failed
  or lost connections and is not persisted as conversation content.
- The app loads local conversation state before asking the store to make one
  guarded automatic connection attempt. Foreground activation calls the same
  idempotent entry point, so lifecycle changes cannot create connection loops.

### Domain

- `Models/SessionModels.swift` contains connection state, transcript records,
  session metadata, normalized transport events, and the optional
  `SpeechTiming`/`SpeechTimingWord` caption-timing contract.
- These types should remain independent of SwiftUI where practical so they are
  easy to test.

### Transport

- `Services/HermesSessionClient.swift` defines the async client contract.
- The eventual WebSocket implementation will own JSON encoding/decoding,
  reconnect policy, one-reader enforcement, and protocol diagnostics.
- Views and the store must not parse raw protocol frames.

### Platform capabilities

- Keychain-backed profile/token storage is shared across iOS and macOS.
- Microphone permission, speech recognition, audio routing, and sandbox
  entitlements are implemented by platform adapters.
- Signed 16-bit PCM playback and WAV fallback remain behind the shared
  `AudioOutput` protocol.
- `AudioOutput.playbackPosition()` reports the elapsed position of the active
  inbound audio stream when the platform can provide it. The voice coordinator
  samples that position while streamed PCM or decoded audio-file playback is
  active, publishes the corresponding received-audio duration, groups timing
  revisions by segment ID, and clears the timeline on a new turn or
  interruption.
- `AudioActivityStore` receives normalized microphone and inbound-playback
  levels, classifies microphone silence/background noise/speech, and emits a
  throttled newest-snapshot stream. It carries no prompt, transcript, or raw
  PCM data. Permission, route, and lifecycle failures publish explicit safe
  states; it does not itself arm hands-free mode or trigger interruption.
- `AmbientHUDPresentation` maps `VoiceState`, the current activity snapshot,
  provisional speech text, and persisted transcript records into one display
  state. The visualizer is presentation-only: it never infers a relay control
  operation or starts capture.
- `RecentTranscriptProjection` preserves the complete text of the latest six
  meaningful transcript entries and appends provisional user speech at a
  stable live anchor. The rail limits viewport height, not message content, so
  long Hermes responses remain scrollable and are never silently truncated.
- `RecentTranscriptRail` uses accumulated `SpeechTiming` word boundaries and
  playback position to reveal the active Hermes response. When the relay has
  not supplied word timings, it uses playback position against the received
  PCM/WAV duration as an overall-cadence fallback. It validates timed and
  duration-based prefixes against the visible transcript, never regresses an
  already revealed prefix, and falls back to the existing word-paced reveal
  when audio timing is unavailable.

### Later local capabilities

- Keychain-backed profile/token storage.
- Microphone capture and permission state.
- Signed 16-bit PCM playback and WAV fallback.
- Session browser and transcript hydration once the relay supports those
  operations.

## Concurrency rule

The store is main-actor isolated. Transport work, speech recognition, and audio
I/O must stay off the main actor, delivering typed events back to the store.
There must be one reader for a WebSocket; do not add independent `receive`
loops for UI features.

## Error rule

Every unsupported or unavailable operation must produce an actionable local
state. A failed connection is not a connected session, and a transport event
that the app cannot safely interpret must not become model prose.
