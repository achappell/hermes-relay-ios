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
- `ViewModels/ConversationStore.swift` owns main-actor conversation state and
  turns typed client events into transcript records.

### Domain

- `Models/SessionModels.swift` contains connection state, transcript records,
  session metadata, and normalized transport events.
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
