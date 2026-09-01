import XCTest
@testable import HermesRelayIOS

final class HermesRelayIOSTests: XCTestCase {
    func testUnavailableClientExplainsMissingRelayWiring() async {
        do {
            _ = try await UnavailableHermesSessionClient().connect()
            XCTFail("The foundation client must not claim a connection")
        } catch let error as RelayUnavailableError {
            XCTAssertEqual(error.errorDescription, "The Hermes relay client is not wired yet.")
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
}
