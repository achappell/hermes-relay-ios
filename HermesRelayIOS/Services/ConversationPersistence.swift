import Foundation

protocol ConversationPersistence: Sendable {
    func load() async throws -> PersistedConversation
    func save(_ conversation: PersistedConversation) async throws
}

struct PersistedConversation: Codable, Equatable, Sendable {
    let messages: [TranscriptMessage]
    let draft: String
    let unconfirmedTurnText: String?

    init(
        messages: [TranscriptMessage],
        draft: String,
        unconfirmedTurnText: String? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.unconfirmedTurnText = unconfirmedTurnText
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
