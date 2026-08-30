
# Native Voice Interface Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver a native push-to-talk voice conversation path across the intentional iOS 26 and macOS 26 targets: secure configuration, Hermes WebSocket text turns, local transcription, streamed PCM playback, clear lifecycle state, and recoverable failures.

**Architecture:** Keep SwiftUI above the main-actor ConversationStore and a focused VoiceSessionCoordinator. Keep protocol encoding, one-reader WebSocket transport, and event normalization in an actor-backed client. Keep speech input, microphone permission, audio routing, and PCM playback behind injectable Sendable adapters so simulator tests use deterministic fakes and device tests cover hardware behavior.

**Tech Stack:** Swift 6 language mode, Xcode 26.6, SwiftUI, Observation, Foundation, URLSessionWebSocketTask, Security/Keychain, AVFoundation, Speech, XCTest, iOS 26, and macOS 26.

**Spec:** docs/superpowers/specs/2026-08-30-ios-voice-interface-design.md

## Global Constraints

- Build targets intentionally support iphoneos, iphonesimulator, and macosx.
- The app uses iOS 26 and macOS 26 deployment targets.
- Shared domain, transport, and state code must compile on both platforms.
- Platform conditionals are limited to microphone permission, speech recognition, audio routing, entitlements, and minor toolbar/layout differences.
- The first hardware smoke path is iOS; macOS receives compile and sandbox-capability validation.
- The first voice path is push-to-talk → local transcription → text turn → streamed PCM playback.
- Do not add microphone upload, remote interrupt, steer, approval, sudo, secret-prompt, session-browser, or server-transcript-hydration operations.
- A hello_ack is required before reporting a connected state.
- A WebSocket has exactly one receive loop.
- Unit tests use fakes and deterministic events; no live Hermes endpoint or credential is required by XCTest.
- Bearer tokens, prompt text, response text, audio contents, signing certificates, and device credentials never enter source, fixtures, screenshots, or logs.
- Every task ends with a focused test or deterministic validation and a conventional commit containing only that task’s files.

---

## Task 1: Reconcile platform documentation and validation commands

**Objective:** Make repository documentation match the intentional iOS 26/macOS 26 project settings before feature work begins.

**Files:**
- Modify: AGENTS.md:52-66
- Modify: README.md:24-71
- Modify: docs/architecture.md:29-57
- Modify: docs/workflow.md:34-55
- Modify: docs/plans/2026-08-30-ios-01-foundation-plan.md:1-76
- Modify: docs/plans/2026-08-30-ios-01-foundation-testing-plan.md:1-30

**Interfaces:**
- Consumes: the existing HermesRelayIOS.xcodeproj target matrix.
- Produces: one documented platform matrix and one build/test command set that explicitly selects iOS or macOS.

- [ ] Step 1: Update the platform requirements.

Replace the old iOS-17-only statements with:

    - macOS with Xcode 26.6 or newer
    - Swift 6.3 or newer
    - iOS 26 or newer for the iOS target
    - macOS 26 or newer for the macOS target

State that the target intentionally includes iphoneos, iphonesimulator, and macosx, while the first hardware voice validation is iOS. Update the active IOS-01 foundation plan’s toolchain and follow-up slice list at the same time.

- [ ] Step 2: Make validation destination-specific.

Document these exact commands:

    xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

    xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

Explain that omitting -destination allows Xcode to select macOS because macOS is intentionally supported.

- [ ] Step 3: Update the foundation smoke plan.

Keep the unavailable-relay checks, and add a platform check that launches the app once on iOS Simulator and once on macOS, confirming that the same shell remains honest on both targets.

- [ ] Step 4: Review the documentation for protocol boundaries.

Confirm that the docs still say local cancellation is local only, microphone upload is unsupported, and remote interruption is deferred to RELAY-01.

- [ ] Step 5: Validate and commit.

Run:

    git diff --check
    git diff -- AGENTS.md README.md docs/architecture.md docs/workflow.md docs/plans/2026-08-30-ios-01-foundation-testing-plan.md
    git add AGENTS.md README.md docs/architecture.md docs/workflow.md docs/plans/2026-08-30-ios-01-foundation-plan.md docs/plans/2026-08-30-ios-01-foundation-testing-plan.md
    git commit -m "docs: align iOS voice platform matrix"

Expected: no whitespace errors; only the six documentation files are committed. Do not stage the existing user-owned HermesRelayIOS.xcodeproj/project.pbxproj change unless it is part of a later capability task.

---

## Task 2: Add the shared profile model and Keychain storage

**Objective:** Store the relay endpoint and non-secret client metadata as a profile while storing the bearer token only in Keychain.

**Files:**
- Create: HermesRelayIOS/Models/RelayProfile.swift
- Create: HermesRelayIOS/Services/SecureValueStore.swift
- Create: HermesRelayIOS/Services/RelayConfigurationStore.swift
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/RelayConfigurationTests.swift

**Interfaces:**
- Consumes: Foundation and Security.
- Produces:

    struct RelayProfile: Codable, Equatable, Sendable {
        let endpoint: URL
        let clientID: String
        let deviceID: String
        let displayName: String
    }

    protocol SecureValueStore: Sendable {
        func read(service: String, account: String) throws -> Data?
        func write(_ value: Data, service: String, account: String) throws
        func delete(service: String, account: String) throws
    }

    actor RelayConfigurationStore {
        init(secureStore: any SecureValueStore, profileURL: URL)
        func loadProfile() async throws -> RelayProfile?
        func saveProfile(_ profile: RelayProfile) async throws
        func loadToken() async throws -> String?
        func saveToken(_ token: String) async throws
        func deleteToken() async throws
    }

- [ ] Step 1: Write Keychain and profile tests.

Add a fake SecureValueStore, register RelayConfigurationTests.swift in the HermesRelayIOSTests target, and add tests for:

    func testMissingProfileIsExplicitlyUnconfigured() throws
    func testSavingAndLoadingProfileDoesNotRequireTheToken() throws
    func testSavingAndLoadingTokenUsesTheSecureStore() throws
    func testDeletingTokenLeavesTheProfileIntact() throws
    func testInvalidEndpointIsRejectedBeforeAClientIsBuilt() throws

- [ ] Step 2: Run the focused tests and verify the red boundary.

Run:

    xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -only-testing:HermesRelayIOSTests/RelayConfigurationTests test

Expected: the new tests fail because the model, store, and production Keychain adapter do not exist.

- [ ] Step 3: Implement the model and in-memory fake.

Make RelayProfile Codable, Equatable, and Sendable. Reject empty client/device/display values and non-ws/wss endpoints in the configuration layer. Keep token data out of RelayProfile.

- [ ] Step 4: Implement the production Keychain adapter.

Use kSecClassGenericPassword with service com.achappell.HermesRelayIOS.profile and account default-token. Use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly on iOS. Convert non-success Security status codes into a local error containing the status name but never the token.

- [ ] Step 5: Implement the actor-backed configuration store and wire files into both targets.

Add the new Swift files to the app and test target source phases. Keep the store’s profile file in Application Support and its token in Keychain. Do not print either value.

- [ ] Step 6: Run the focused tests and commit.

Expected: all five configuration tests pass on the iOS destination. Commit:

    git add HermesRelayIOS/Models/RelayProfile.swift HermesRelayIOS/Services/SecureValueStore.swift HermesRelayIOS/Services/RelayConfigurationStore.swift HermesRelayIOSTests/RelayConfigurationTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: add secure relay configuration"

---

## Task 3: Add platform privacy and sandbox capability declarations

**Objective:** Make microphone, speech, network, and macOS sandbox requirements explicit before production audio code requests access.

**Files:**
- Create: HermesRelayIOS/HermesRelayIOS.entitlements
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: the intentional app target settings and RelayConfigurationStore.
- Produces: generated privacy strings and a macOS entitlement file registered through CODE_SIGN_ENTITLEMENTS.

- [ ] Step 1: Inspect the target-specific capability settings.

Do not duplicate Xcode build configuration in an XCTest helper. Inspect the effective settings directly:

    xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'generic/platform=iOS Simulator' -showBuildSettings | rg 'IPHONEOS_DEPLOYMENT_TARGET|INFOPLIST_KEY_NS(Microphone|SpeechRecognition)UsageDescription|SUPPORTED_PLATFORMS'

Also inspect the macOS target settings for MACOSX_DEPLOYMENT_TARGET, CODE_SIGN_ENTITLEMENTS, and ENABLE_OUTGOING_NETWORK_CONNECTIONS.

- [ ] Step 2: Add the generated usage descriptions and entitlements.

Set these exact strings in the app target’s Debug and Release settings:

    INFOPLIST_KEY_NSMicrophoneUsageDescription = "Hermes uses the microphone for push-to-talk voice turns."
    INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Hermes uses speech recognition to turn a voice turn into text."

- [ ] Step 4: Add macOS entitlements.

Register HermesRelayIOS/HermesRelayIOS.entitlements and include:

    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>

Keep the entitlements file free of tokens, profile values, and device identifiers.

- [ ] Step 5: Build both target families and commit.

Run the iOS and macOS build commands from Task 1, lint the entitlement file, and verify the effective macOS settings:

    plutil -lint HermesRelayIOS/HermesRelayIOS.entitlements
    xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS,arch=arm64' -showBuildSettings | rg 'MACOSX_DEPLOYMENT_TARGET|CODE_SIGN_ENTITLEMENTS|ENABLE_OUTGOING_NETWORK_CONNECTIONS'

Then commit:

    git add HermesRelayIOS/HermesRelayIOS.entitlements HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "chore: declare voice platform capabilities"

---

## Task 4: Normalize Hermes protocol events into typed Swift values

**Objective:** Give the transport and UI a typed event boundary for streamed text, activity, audio, errors, and completion.

**Files:**
- Modify: HermesRelayIOS/Models/SessionModels.swift:1-61
- Create: HermesRelayIOS/Services/HermesEventNormalizer.swift
- Modify: HermesRelayIOS/ViewModels/ConversationStore.swift:59-78
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/HermesEventNormalizerTests.swift

**Interfaces:**
- Consumes: JSON object dictionaries and binary WebSocket frames from the transport.
- Produces:

    struct AudioFormat: Equatable, Sendable {
        let sampleRate: Int
        let channels: Int
        let sampleWidth: Int
    }

    enum HermesEvent: Equatable, Sendable {
        case messageStart
        case textDelta(String)
        case textReplace(String)
        case thinkingDelta(String)
        case status(text: String, kind: String?)
        case audioStart(AudioFormat)
        case audioChunk(Data)
        case audioEnd
        case messageComplete(text: String, reasoning: String, failureReason: String)
        case turnComplete(turnID: String)
        case error(String)
        case unknown(type: String)
    }

    struct HermesEventNormalizer: Sendable {
        mutating func normalizeJSON(_ data: Data, turnID: String) throws -> [HermesEvent]
        func normalizeBinary(_ data: Data, audioFileActive: Bool) -> HermesEvent
    }

- [ ] Step 1: Write normalization tests.

Cover these exact frames:

    func testTextDeltaUsesOnlyTheUnseenCumulativeSuffix() throws
    func testTextFinalMatchingThePreviewProducesNoDuplicateText() throws
    func testTextReplacementReplacesARevisedPreview() throws
    func testStatusAndThinkingActivityRemainTyped() throws
    func testAudioStartUsesDeclaredDefaultsAndAudioChunksRemainBinary() throws
    func testErrorStopsWithTheServerMessageOrFallback() throws
    func testUnknownEventsAreContentSafe() throws

Use JSON fixtures with short synthetic text only. Do not use prompts, bearer tokens, or captured audio.

- [ ] Step 2: Run the focused normalizer tests and verify the red boundary.

Expected: the tests fail because AudioFormat, the expanded HermesEvent, and the normalizer do not exist.

- [ ] Step 3: Implement text normalization.

Port the sibling TUI’s append/replace behavior: cumulative previews emit only unseen suffixes, explicit replace emits .textReplace, a non-prefix rewind emits a new replacement, and terminal text matching the preview emits no duplicate.

- [ ] Step 4: Implement activity, audio, error, and completion normalization.

Accept both top-level and nested payload fields. Defaults for audio_start are sample rate 24000, one channel, and sample width 2. Return multiple events when a terminal frame needs both a text update and a completion event. Unknown JSON kinds become .unknown(type:) without retaining the raw payload.

Update the existing store switch to consume the expanded event enum without parsing raw transport data; audio and unknown events remain transport/coordinator concerns.

- [ ] Step 5: Run the focused tests and commit.

Expected: all normalizer tests pass. Commit:

    git add HermesRelayIOS/Models/SessionModels.swift HermesRelayIOS/Services/HermesEventNormalizer.swift HermesRelayIOSTests/HermesEventNormalizerTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: normalize Hermes voice events"

---

## Task 5: Implement the actor-backed WebSocket Hermes client

**Objective:** Connect to Hermes, gate connection on hello_ack, send typed text turns, and expose one normalized event stream without letting raw frames reach the store.

**Files:**
- Modify: HermesRelayIOS/Services/HermesSessionClient.swift:1-31
- Create: HermesRelayIOS/Services/WebSocketConnection.swift
- Create: HermesRelayIOS/Services/URLSessionHermesSessionClient.swift
- Modify: HermesRelayIOS/ViewModels/ConversationStore.swift:33-52
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/URLSessionHermesSessionClientTests.swift

**Interfaces:**
- Consumes: RelayProfile, RelayConfigurationStore, and HermesEventNormalizer.
- Produces:

    enum WebSocketFrame: Equatable, Sendable {
        case text(String)
        case binary(Data)
    }

    protocol WebSocketConnection: Sendable {
        func send(text: String) async throws
        func receive() async throws -> WebSocketFrame
        func close() async
    }

    protocol WebSocketConnectionFactory: Sendable {
        func open(urlRequest: URLRequest) async throws -> any WebSocketConnection
    }

    protocol HermesSessionClient: Sendable {
        func connect() async throws -> SessionMetadata
        func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error>
        func disconnect() async
    }

    actor URLSessionHermesSessionClient: HermesSessionClient {
        init(profile: RelayProfile, token: String, socketFactory: any WebSocketConnectionFactory)
        func connect() async throws -> SessionMetadata
        func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error>
        func disconnect() async
    }

- [ ] Step 1: Write fake-socket tests.

Cover these exact scenarios:

    func testConnectSendsProtocolV1HelloAndWaitsForHelloAck() async throws
    func testConnectRejectsAnAckWithTheWrongType() async throws
    func testSendTurnIncludesUniqueTurnIDSessionIDTextAndLocalSTTSource() async throws
    func testSendTurnStreamsNormalizedTextAndTurnCompletion() async throws
    func testBinaryFramesBecomeAudioChunksOnlyAfterAudioStart() async throws
    func testServerErrorFinishesTheTurnWithAnActionableError() async throws
    func testDisconnectClosesTheSocketAndCancelsTheSingleReader() async

- [ ] Step 2: Run the focused client tests and verify the red boundary.

Expected: tests fail because the socket abstractions and production actor do not exist.

- [ ] Step 3: Implement the URLSession socket adapter.

Create a URLRequest from the profile endpoint and set Authorization to Bearer <token> without logging the request headers. Map URLSessionWebSocketTask.Message.string to .text and .data to .binary.

- [ ] Step 4: Implement one actor-owned receive loop.

The actor owns the socket, reader task, connection state, and active turn. The reader is the only code that calls receive(). connect() consumes the first normalized handshake result and returns only after hello_ack; async sendTurn(text:) sends one JSON object and returns an event stream that yields until .turnComplete or .error.

- [ ] Step 5: Implement safe close and malformed-frame handling.

Close the socket and finish the active stream on cancellation, server close, invalid JSON, non-object JSON, or an unsupported binary frame before audio has started. Error messages may describe protocol shape but must not include raw payload text.

- [ ] Step 6: Run focused tests and commit.

Expected: all fake-socket tests pass. Commit:

    git add HermesRelayIOS/Services/HermesSessionClient.swift HermesRelayIOS/Services/WebSocketConnection.swift HermesRelayIOS/Services/URLSessionHermesSessionClient.swift HermesRelayIOSTests/URLSessionHermesSessionClientTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: connect iOS client to Hermes relay"

---

## Task 6: Integrate the real client with the typed conversation store

**Objective:** Replace the unavailable client only when configuration is valid, preserve existing draft behavior, and render one stable streamed assistant message.

**Files:**
- Modify: HermesRelayIOS/ViewModels/ConversationStore.swift:1-83
- Modify: HermesRelayIOS/Models/SessionModels.swift:1-61
- Modify: HermesRelayIOS/Views/ContentView.swift:1-127
- Modify: HermesRelayIOS/HermesRelayIOSApp.swift:1-20
- Test: HermesRelayIOSTests/ConversationStoreTransportTests.swift

**Interfaces:**
- Consumes: URLSessionHermesSessionClient, RelayConfigurationStore, and normalized HermesEvent values.
- Produces:

    @MainActor
    init(client: any HermesSessionClient)

    var sessionMetadata: SessionMetadata?
    var isSending: Bool

    func connect() async
    func sendTurn(text: String) async
    func sendDraft() async

- [ ] Step 1: Write fake-client store tests.

Cover connection success/failure, streamed text, text replacement, status, server error, and turn_end. Assert that one assistant record is updated rather than appended for every delta.

- [ ] Step 2: Run the focused store tests and verify the red boundary.

Expected: tests fail for the new metadata, sending state, and event cases.

- [ ] Step 3: Expand ConversationStore.apply(_:).

Handle .textDelta by updating the active assistant message, .textReplace by replacing that message’s text, .status as non-transcript activity, and .turnComplete by clearing the active-turn marker. Implement sendTurn(text:) as the shared path used by both typed drafts and finalized voice recognition; it must append exactly one user message and consume the async client stream. VoiceSessionCoordinator consumes audio events; ConversationStore does not own audio APIs. Never insert raw unknown payloads into messages.

- [ ] Step 4: Wire configured-client creation.

Use an explicit local configuration error when no profile/token exists. Keep UnavailableHermesSessionClient available for previews and foundation smoke tests. Do not make the SwiftUI view read Keychain directly.

Because the production client is actor-isolated, the store consumes its event stream as:

    let events = await client.sendTurn(text: text)
    for try await event in events {
        apply(event)
    }

- [ ] Step 5: Run focused tests and commit.

Expected: all store transport tests pass and the existing foundation tests remain green. Commit:

    git add HermesRelayIOS/ViewModels/ConversationStore.swift HermesRelayIOS/Models/SessionModels.swift HermesRelayIOS/Views/ContentView.swift HermesRelayIOS/HermesRelayIOSApp.swift HermesRelayIOSTests/ConversationStoreTransportTests.swift
    git commit -m "feat: render Hermes text turns in the conversation store"

---

## Task 7: Add injectable speech input and local push-to-talk transcription

**Objective:** Capture a voice turn locally, expose provisional transcription, and submit only a finalized release—not a cancelled capture.

**Files:**
- Create: HermesRelayIOS/Services/SpeechInput.swift
- Create: HermesRelayIOS/Services/AppleSpeechInput.swift
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/SpeechInputTests.swift

**Interfaces:**
- Consumes: platform microphone permission and Speech framework APIs.
- Produces:

    enum SpeechAuthorization: Equatable, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
    }

    struct SpeechRecognitionUpdate: Equatable, Sendable {
        let text: String
        let isFinal: Bool
    }

    protocol SpeechInput: Sendable {
        func authorization() async -> SpeechAuthorization
        func requestAuthorization() async -> SpeechAuthorization
        func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error>
        func cancel() async
    }

- [ ] Step 1: Write deterministic speech fake tests.

Cover authorized start, denied permission, partial updates, final update, capture error, release, and cancellation. Assert cancellation emits no final text.

- [ ] Step 2: Run the focused tests and verify the red boundary.

Expected: tests fail because the protocol, fake, and production adapter do not exist.

- [ ] Step 3: Implement the fake and authorization mapping.

Keep all permission outcomes typed. Map SFSpeechRecognizerAuthorizationStatus and microphone permission status to SpeechAuthorization without putting framework objects into the domain layer.

- [ ] Step 4: Implement the Apple adapter.

Use AVAudioEngine with SFSpeechAudioBufferRecognitionRequest. Prefer on-device recognition when supported. Deliver partial results through AsyncThrowingStream; stop the engine and remove the tap in both final and cancellation paths.

- [ ] Step 5: Validate cleanup and commit.

Run the focused fake tests, build both target families, and commit:

    git add HermesRelayIOS/Services/SpeechInput.swift HermesRelayIOS/Services/AppleSpeechInput.swift HermesRelayIOSTests/SpeechInputTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: add local push-to-talk transcription"

---

## Task 8: Add injectable signed-16-bit PCM playback and WAV fallback

**Objective:** Play Hermes’ declared PCM stream in order while keeping text visible and recovery possible when live playback fails.

**Files:**
- Create: HermesRelayIOS/Services/AudioOutput.swift
- Create: HermesRelayIOS/Services/AppleAudioOutput.swift
- Create: HermesRelayIOS/Services/WAVFallbackWriter.swift
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/AudioOutputTests.swift

**Interfaces:**
- Consumes: AudioFormat and .audioStart/.audioChunk/.audioEnd events.
- Produces:

    protocol AudioOutput: Sendable {
        func start(format: AudioFormat) async throws
        func append(_ pcm: Data) async throws
        func finish() async
        func stop() async
    }

    struct WAVFallbackWriter: Sendable {
        func write(pcm: Data, format: AudioFormat) throws -> URL
    }

- [ ] Step 1: Write fake-output tests.

Cover format acceptance, chunk ordering, finish cleanup, stop cleanup, unsupported sample width, output failure, and fallback WAV header/frame values.

- [ ] Step 2: Run the focused tests and verify the red boundary.

Expected: tests fail because the output protocols and adapters do not exist.

- [ ] Step 3: Implement the fake and WAV writer.

Accept only signed 16-bit PCM (sampleWidth == 2). Write fallback files under the app’s temporary or Application Support audio directory, never the repository. Include the declared sample rate and channel count in the WAV header.

- [ ] Step 4: Implement AppleAudioOutput.

Configure AVAudioSession on iOS and the equivalent AVAudioEngine output path on macOS. Use AVAudioPlayerNode or an equivalent buffered PCM path. Keep the audio engine off the main actor and serialize start, append, finish, and stop.

- [ ] Step 5: Test failure recovery and commit.

When start or append fails, close the live path, retain buffered PCM for the fallback writer, and report a local playback error while leaving transcript text intact. Commit:

    git add HermesRelayIOS/Services/AudioOutput.swift HermesRelayIOS/Services/AppleAudioOutput.swift HermesRelayIOS/Services/WAVFallbackWriter.swift HermesRelayIOSTests/AudioOutputTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: play Hermes PCM audio with fallback"

---

## Task 9: Coordinate voice turns and expose the lifecycle state

**Objective:** Give the UI one authoritative voice state and integrate speech input, the conversation store, Hermes events, and audio output without transcript noise.

**Files:**
- Modify: HermesRelayIOS/Models/SessionModels.swift:1-61
- Create: HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift
- Create: HermesRelayIOS/Views/VoiceStatusView.swift
- Create: HermesRelayIOS/Views/VoiceControl.swift
- Modify: HermesRelayIOS/Views/ContentView.swift:1-127
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift
- Test: HermesRelayIOSTests/VoiceStatusViewTests.swift

**Interfaces:**
- Consumes: SpeechInput, AudioOutput, ConversationStore, and HermesSessionClient.
- Produces:

    enum VoiceState: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        case buffering
        case interrupted
        case failed(String)
    }

    @MainActor
    @Observable
    final class VoiceSessionCoordinator {
        init(store: ConversationStore, input: any SpeechInput, output: any AudioOutput)
        var state: VoiceState { get }
        var provisionalText: String { get }

        func beginCapture() async
        func endCaptureAndSend() async
        func cancelCapture() async
        func stopPlayback() async
    }

- [ ] Step 1: Write the state-machine tests.

Cover these sequences:

    idle → listening → transcribing → idle
    idle → listening → interrupted → idle
    idle → listening → transcribing → thinking → speaking → idle
    idle → listening → failed("Microphone access is denied.") → idle
    speaking → buffering → idle

Assert that release submits one turn, cancellation submits none, partial recognition remains provisional, and the active assistant message is not duplicated.

- [ ] Step 2: Run the focused coordinator tests and verify the red boundary.

Expected: tests fail because VoiceState, coordinator, and status/control views do not exist.

- [ ] Step 3: Implement the coordinator.

Own one capture task and one response task. On release, trim the final recognition; if empty, return to .idle without sending. On cancellation, cancel the speech adapter and clear only provisional text. Map Hermes status/audio/text events to the state machine and forward transcript mutations to ConversationStore.

- [ ] Step 4: Implement the voice control.

Use a press-and-hold interaction that starts on press and ends on release. Add an explicit cancel action for accessibility and an accessibility label that includes the current state, such as Voice control, listening.

- [ ] Step 5: Implement the compact status surface.

Render one state label and one system image from VoiceState. Do not add listening, thinking, or audio status lines to the transcript. Show failures with the next action, such as Microphone access is denied. Allow microphone access in Settings.

- [ ] Step 6: Run focused tests and commit.

Expected: coordinator and status tests pass, and the existing conversation tests remain green. Commit:

    git add HermesRelayIOS/Models/SessionModels.swift HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift HermesRelayIOS/Views/VoiceStatusView.swift HermesRelayIOS/Views/VoiceControl.swift HermesRelayIOS/Views/ContentView.swift HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift HermesRelayIOSTests/VoiceStatusViewTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: add voice lifecycle coordination"

---

## Task 10: Add local continuity and recoverable reconnect behavior

**Objective:** Preserve drafts and local conversation state without replaying an ambiguous remote turn or claiming server confirmation.

**Files:**
- Create: HermesRelayIOS/Services/ConversationPersistence.swift
- Modify: HermesRelayIOS/ViewModels/ConversationStore.swift:1-83
- Modify: HermesRelayIOS/Services/URLSessionHermesSessionClient.swift
- Modify: HermesRelayIOS.xcodeproj/project.pbxproj
- Test: HermesRelayIOSTests/ConversationPersistenceTests.swift
- Test: HermesRelayIOSTests/RecoveryTests.swift

**Interfaces:**
- Consumes: transcript records, draft text, connection state, and stable turn_id values.
- Produces:

    protocol ConversationPersistence: Sendable {
        func load() async throws -> PersistedConversation
        func save(_ conversation: PersistedConversation) async throws
    }

    struct PersistedConversation: Codable, Equatable, Sendable {
        let messages: [TranscriptMessage]
        let draft: String
    }

- [ ] Step 1: Write persistence and recovery tests.

Cover empty load, save/load round-trip, corrupted file, draft preservation across a failed send, disconnect during a turn, reconnect without replay, and cleanup after a completed turn.

- [ ] Step 2: Run the focused tests and verify the red boundary.

Expected: tests fail because persistence and recovery behavior do not exist.

- [ ] Step 3: Make transcript records persistable and implement an actor-backed local JSON store.

Add Codable conformance to TranscriptMessage, then store transcript and draft JSON under Application Support. Apply iOS file protection where available. Never persist bearer tokens, raw WebSocket frames, audio bytes, or server-unconfirmed session metadata.

- [ ] Step 4: Track ambiguous turns explicitly.

When a socket closes after a turn is sent but before turn_end, mark the local turn as interrupted/unconfirmed. Reconnect may establish a new connection, but it must not resend that text automatically.

- [ ] Step 5: Run focused tests and commit.

Expected: persistence and recovery tests pass. Commit:

    git add HermesRelayIOS/Services/ConversationPersistence.swift HermesRelayIOS/ViewModels/ConversationStore.swift HermesRelayIOS/Services/URLSessionHermesSessionClient.swift HermesRelayIOSTests/ConversationPersistenceTests.swift HermesRelayIOSTests/RecoveryTests.swift HermesRelayIOS.xcodeproj/project.pbxproj
    git commit -m "feat: preserve local voice conversation state"

---

## Task 11: Add the voice manual smoke plan and validation ladder

**Objective:** Prove the voice MVP on iOS hardware and verify macOS build/sandbox behavior without putting credentials or audio into repository artifacts.

**Files:**
- Create: docs/plans/2026-08-30-ios-voice-interface-testing-plan.md
- Modify: README.md
- Modify: docs/workflow.md

**Interfaces:**
- Consumes: all completed voice slices and the secure local configuration path.
- Produces: copy-paste simulator, macOS, and iOS-device validation steps with evidence fields.

- [ ] Step 1: Document automated validation.

Use this ladder:

    Focused XCTest
        ↓
    iOS Simulator build
        ↓
    iOS Simulator XCTest
        ↓
    macOS build with sandbox enabled
        ↓
    iOS device voice smoke test
        ↓
    Project #3 evidence

- [ ] Step 2: Document the iOS-device walkthrough.

The plan must cover:

1. Missing profile/token and recoverable configuration wording.
2. Successful connect after hello_ack.
3. Press-and-hold capture with listening and provisional transcription.
4. Release → one user text turn → streamed assistant text → PCM playback.
5. Cancel during capture → no submitted turn and preserved draft.
6. Microphone denial → actionable Settings guidance.
7. Speaker/playback failure → visible text plus fallback/error wording.
8. Network loss → disconnected state, reconnect, and no automatic replay.
9. No prompt, response, token, or audio contents in logs.

- [ ] Step 3: Document the macOS path.

Build with the macOS destination, confirm the sandbox entitlements are present, launch the shared shell, and verify that the app does not claim a connected relay without valid configuration.

- [ ] Step 4: Run automated checks and the manual plan.

Run both destination-specific builds, the focused XCTest targets, the complete XCTest target, and the device smoke plan. Attach only counts, state transitions, error wording, and screenshots that contain no private content.

- [ ] Step 5: Commit validation documentation.

    git add docs/plans/2026-08-30-ios-voice-interface-testing-plan.md README.md docs/workflow.md
    git commit -m "docs: add iOS voice validation plan"

---

## Task 12: Close the slices on Project #3

**Objective:** Move each completed slice through Inbox → Ready → Building → Verify → Done with implementation and validation evidence, while keeping only one iOS slice active.

**Files:**
- No repository files; update GitHub Project #3 items.

**Interfaces:**
- Consumes: commits, focused XCTest output, destination-specific build output, and manual smoke evidence.
- Produces: draft items for IOS-02, IOS-03, VOICE-04, VOICE-05, VOICE-06, and IOS-07, each with an outcome, acceptance criteria, UX expectation, dependency, and validation scenario.

- [ ] Step 1: Leave IOS-01 as the current active item.

Do not move IOS-01 to Done until Task 1 and the foundation iOS/macOS validation are complete.

- [ ] Step 2: Create follow-up items in Inbox with built-in status Todo.

Use the exact slice titles from Tasks 2, 5, 7, 8, 9, and 10. Keep RELAY-01 and SESSION-01 as dependencies rather than folding their work into an iOS item.

- [ ] Step 3: Record evidence after each slice.

Include focused test names/counts, build destinations, manual steps completed, and any blocked hardware or relay dependency. Never paste credentials, prompts, responses, or audio data into the item.

- [ ] Step 4: Move only the current slice through the workflow.

The next slice enters Building only after the prior slice reaches Done or is explicitly Blocked by a documented external dependency.

---

## Final voice-MVP verification

The plan is complete when a configured user on a real iOS device can connect, press and hold the voice control, see listening and local transcription, release to submit exactly one text-backed Hermes turn, see streamed response text, hear streamed signed-16-bit PCM audio, cancel a later capture without submitting it, and recover from denied microphone access or failed playback without losing the visible response. The macOS target must compile and pass its sandbox-capability check. No client microphone upload or remote interruption may be claimed until Hermes exposes those operations.
