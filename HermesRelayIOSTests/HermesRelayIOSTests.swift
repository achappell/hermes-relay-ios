import XCTest
@testable import HermesRelayIOS

final class HermesRelayIOSTests: XCTestCase {
    func testUnavailableClientExplainsMissingRelayConfiguration() async {
        do {
            _ = try await UnavailableHermesSessionClient().connect()
            XCTFail("The foundation client must not claim a connection")
        } catch let error as RelayUnavailableError {
            XCTAssertEqual(error.errorDescription, "Configure a Hermes relay before connecting.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testStoreKeepsDraftWhenRelayIsUnavailable() async {
        let store = ConversationStore()
        store.draft = "Hello Hermes"

        await store.sendDraft()

        XCTAssertEqual(store.draft, "Hello Hermes")
        XCTAssertEqual(store.transientError, "Connect to the Hermes relay before sending.")
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testConnectionStateLabelsAreActionable() {
        XCTAssertEqual(ConnectionState.disconnected.label, "Not connected")
        XCTAssertEqual(ConnectionState.connecting.label, "Connecting…")
        XCTAssertEqual(ConnectionState.connected.label, "Connected")
        XCTAssertEqual(ConnectionState.failed("offline").label, "Unavailable")
    }

    func testVoiceStatesExposeStableStatusPresentation() {
        let expected: [(VoiceState, String, String)] = [
            (.idle, "Ready", "mic"),
            (.listening, "Listening", "mic.fill"),
            (.transcribing, "Transcribing", "waveform"),
            (.thinking, "Thinking", "ellipsis"),
            (.speaking, "Speaking", "speaker.wave.2.fill"),
            (.buffering, "Buffering", "arrow.down.circle"),
            (.interrupted, "Interrupted", "pause.circle"),
            (.failed("Audio playback failed."), "Audio playback failed.", "exclamationmark.triangle"),
        ]

        for (state, label, systemImage) in expected {
            XCTAssertEqual(state.label, label)
            XCTAssertEqual(state.systemImage, systemImage)
        }
    }

    func testInitialTranscriptScrollTargetsTheLatestMessageOnlyOnce() {
        var state = TranscriptScrollState()
        let first = TranscriptMessage(role: .user, text: "First")
        let latest = TranscriptMessage(role: .assistant, text: "Latest")
        let newer = TranscriptMessage(role: .user, text: "Newer")

        XCTAssertNil(state.targetID(for: []))
        XCTAssertEqual(state.targetID(for: [first, latest]), latest.id)
        XCTAssertNil(state.targetID(for: [first, latest, newer]))
    }
}
