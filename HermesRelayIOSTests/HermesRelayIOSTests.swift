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
}
