import Foundation
import CryptoKit

protocol ConversationPersistence: Sendable {
    func load() async throws -> PersistedConversation
    func save(_ conversation: PersistedConversation) async throws
}

struct PersistedConversation: Codable, Equatable, Sendable {
    let messages: [TranscriptMessage]
    let draft: String
    let unconfirmedTurnText: String?
    let homeRecovery: PersistedHomeRecovery?
    /// Durable upstream session reference; never an authenticated URL or token.
    let standardSessionID: String?
    /// Explicit invalidation survives an empty transcript and a failed New.
    let standardNeedsNewConversation: Bool?

    init(
        messages: [TranscriptMessage],
        draft: String,
        unconfirmedTurnText: String? = nil,
        homeRecovery: PersistedHomeRecovery? = nil,
        standardSessionID: String? = nil,
        standardNeedsNewConversation: Bool? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.unconfirmedTurnText = unconfirmedTurnText
        self.homeRecovery = homeRecovery
        self.standardSessionID = standardSessionID
        self.standardNeedsNewConversation = standardNeedsNewConversation
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

    static func url(in directory: URL, for profile: RelayProfile) -> URL {
        guard let target = profile.standardProfile else { return url(in: directory, for: profile.id) }
        // Length-delimited identity components avoid ambiguous concatenation.
        let endpoint = profile.endpoint.absoluteString
        let identity = "standard:\(endpoint.utf8.count):\(endpoint):\(target.utf8.count):\(target)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("conversation-standard-\(profile.id.uuidString)-\(digest).json")
    }

    static func delete(in directory: URL, for profileID: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let legacyName = "conversation-\(profileID.uuidString).json"
        let prefix = "conversation-standard-\(profileID.uuidString)-"
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if url.lastPathComponent == legacyName
                || (url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json") {
                try FileManager.default.removeItem(at: url)
            }
        }
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
