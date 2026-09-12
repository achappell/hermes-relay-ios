# IOS-26 server-confirmed interruption validation

## Scope

IOS-26 adopts the Hermes protocol-v1 interruption contract without inventing a
new server operation. The client reads `hello_ack.capabilities`, sends one
`interrupt` for the active `turn_id` when the endpoint advertises
`interrupt`, stops playback on `audio_abort`, and waits for `turn_interrupted`.
An endpoint without the capability, or one that does not confirm before the
bounded timeout, uses the existing close-and-reconnect fallback and leaves the
submitted turn unconfirmed.

The transport keeps one WebSocket reader. Turn IDs gate text and JSON events;
binary frames buffered behind a confirmed interruption are discarded until the
next audio stream is described. No prompts, response text, bearer tokens,
raw frames, microphone captures, or PCM contents belong in test artifacts or
diagnostics.

## Deterministic validation

Run the following focused XCTest cases on the configured iPhone 17 Pro iOS
26.5 simulator:

- `HermesEventNormalizerTests/testInterruptEventsRemainTypedWithTheirTurnIdentity`
- `URLSessionHermesSessionClientTests/testInterruptSendsTheActiveTurnCommandAndWaitsForConfirmation`
- `URLSessionHermesSessionClientTests/testInterruptCapabilityCanBeReadFromNestedHelloAckPayload`
- `URLSessionHermesSessionClientTests/testInterruptConfirmationTimeoutFallsBackWithoutClosingTheSocket`
- `URLSessionHermesSessionClientTests/testSendTurnIgnoresLateFramesForAnotherTurn`
- `ConversationStoreTransportTests/testServerConfirmedInterruptKeepsConnectionAndDoesNotMarkTurnUnconfirmed`
- `VoiceSessionCoordinatorTests/testAudioAbortStopsPlaybackWithoutTurningAnIntentionalInterruptIntoFailure`
- `VoiceSessionCoordinatorTests/testServerConfirmedInterruptStopsPlaybackWithoutDisconnecting`
- `VoiceSessionCoordinatorTests/testInterruptStopsPlaybackReconnectsAndBeginsNewCapture`

The supported path must produce one interrupt frame, consume
`audio_abort`/`turn_interrupted`, stop output, preserve partial assistant text,
keep the connection connected, and send no replacement turn. The legacy path
must disconnect/reconnect and mark the submitted text unconfirmed. Late text,
completion, and binary frames must not appear in the next turn.

## iOS device smoke

With a locally configured test relay and a non-sensitive test prompt:

1. Connect and verify the app reports Connected only after `hello_ack`.
2. Start a voice turn and interrupt while Hermes is streaming text and PCM.
3. Verify speech stops immediately, the partial answer remains visible, the
   HUD reports Interrupted, and the connection remains Connected when
   `interrupt` is advertised.
4. Confirm the next capture can be started and released as one separate turn;
   the interrupt itself must not submit a replacement turn.
5. Repeat against a legacy endpoint and verify bounded reconnect plus the
   existing unconfirmed-turn wording.
6. Review diagnostics for content safety: only state, IDs/counts, formats,
   and bounded error wording may be present.

## Closure evidence

Amanda confirmed that the real-device walkthrough was completed on 2026-09-11.
The focused iOS simulator verification was rerun during closeout: 127 selected
tests passed with zero failures, including the supported-interrupt and legacy
fallback paths. No prompt, response, token, raw frame, PCM, or microphone
content was recorded in the repository.
