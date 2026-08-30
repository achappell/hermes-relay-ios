import Foundation
import XCTest
@testable import HermesRelayIOS

final class ConversationPersistenceTests: XCTestCase {
    func testMissingFileLoadsAnEmptyConversation() async throws {
        let fileURL = temporaryFileURL()
        let persistence = JSONConversationPersistence(fileURL: fileURL)

        let conversation = try await persistence.load()

        XCTAssertEqual(conversation, PersistedConversation(messages: [], draft: ""))
    }

    func testSaveAndLoadRoundTripPreservesLocalConversation() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let persistence = JSONConversationPersistence(fileURL: fileURL)
        let message = TranscriptMessage(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            role: .assistant,
            text: "Saved locally"
        )
        let conversation = PersistedConversation(
            messages: [message],
            draft: "Unsent draft"
        )

        try await persistence.save(conversation)
        let loaded = try await persistence.load()

        XCTAssertEqual(loaded, conversation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptedConversationFileFailsSafely() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        let persistence = JSONConversationPersistence(fileURL: fileURL)

        do {
            _ = try await persistence.load()
            XCTFail("Corrupted local state must not be treated as a valid conversation")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesConversationTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}
