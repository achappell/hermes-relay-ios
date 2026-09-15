import Foundation

protocol ConversationPersistence: Sendable {
    func load() async throws -> PersistedConversation
    func save(_ conversation: PersistedConversation) async throws
}

struct PersistedConversation: Codable, Equatable, Sendable {
    let messages: [TranscriptMessage]
    let draft: String
    let unconfirmedTurnText: String?
    let homeRecovery: PersistedHomeRecovery?

    init(
        messages: [TranscriptMessage],
        draft: String,
        unconfirmedTurnText: String? = nil,
        homeRecovery: PersistedHomeRecovery? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.unconfirmedTurnText = unconfirmedTurnText
        self.homeRecovery = homeRecovery
    }
}

actor JSONConversationPersistence: ConversationPersistence {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() async throws -> PersistedConversation {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistedConversation(messages: [], draft: "")
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(PersistedConversation.self, from: data)
    }

    func save(_ conversation: PersistedConversation) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(conversation)
        try data.write(to: fileURL, options: .atomic)

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}


/// Conversations are stored one file per relay profile. Separate files delete
/// with their profile and cannot leak into each other through an indexing
/// mistake, which a single keyed file would always be one bug away from.
enum ConversationPersistenceFile {
    static func url(in directory: URL, for profileID: UUID) -> URL {
        directory.appendingPathComponent("conversation-\(profileID.uuidString).json")
    }

    static let legacyName = "conversation.json"
}

enum ConversationPersistenceMigrator {
    /// Hand the pre-profiles conversation to whichever profile is active.
    ///
    /// The file is moved rather than copied, so a later launch cannot adopt
    /// the same history for a second profile.
    static func migrateLegacyConversation(in directory: URL, to profileID: UUID) {
        let legacyURL = directory.appendingPathComponent(
            ConversationPersistenceFile.legacyName
        )
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        let destination = ConversationPersistenceFile.url(in: directory, for: profileID)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? FileManager.default.moveItem(at: legacyURL, to: destination)
    }
}
