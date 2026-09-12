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

    // Conversations belong to a relay, not to the device. Switching profiles
    // must not render or persist another account's messages.
    @MainActor
    func testEachProfileKeepsItsOwnConversation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-PerProfile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID()
        let second = UUID()
        let factory: @Sendable (UUID) -> any ConversationPersistence = { id in
            JSONConversationPersistence(
                fileURL: directory.appendingPathComponent("conversation-\(id.uuidString).json")
            )
        }

        try await factory(first).save(
            PersistedConversation(
                messages: [TranscriptMessage(role: .user, text: "first account")],
                draft: ""
            )
        )
        try await factory(second).save(
            PersistedConversation(
                messages: [TranscriptMessage(role: .user, text: "second account")],
                draft: ""
            )
        )

        let loadedFirst = try await factory(first).load()
        let loadedSecond = try await factory(second).load()
        XCTAssertEqual(loadedFirst.messages.map(\.text), ["first account"])
        XCTAssertEqual(loadedSecond.messages.map(\.text), ["second account"])
    }

    @MainActor
    func testLegacyConversationMovesToTheActiveProfileExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-Legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("conversation.json")
        try JSONEncoder().encode(
            PersistedConversation(
                messages: [TranscriptMessage(role: .user, text: "history from before profiles")],
                draft: "unsent"
            )
        ).write(to: legacyURL)
        let profile = UUID()

        ConversationPersistenceMigrator.migrateLegacyConversation(
            in: directory, to: profile
        )
        // A second launch must not adopt it again for a different profile.
        ConversationPersistenceMigrator.migrateLegacyConversation(
            in: directory, to: UUID()
        )

        let migrated = try await JSONConversationPersistence(
            fileURL: directory.appendingPathComponent("conversation-\(profile.uuidString).json")
        ).load()
        XCTAssertEqual(migrated.messages.map(\.text), ["history from before profiles"])
        XCTAssertEqual(migrated.draft, "unsent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }
}
