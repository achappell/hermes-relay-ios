import Foundation

/// Every saved relay and which one is active.
///
/// `schemaVersion` is present from the first release so a later change is a
/// cheap migration rather than guesswork about which shape is on disk.
struct RelayProfileCollection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: [RelayProfile]
    var selectedID: UUID?
    var homeMigrations: [UUID: HomeMigrationJournal]

    init(
        schemaVersion: Int = RelayProfileCollection.currentSchemaVersion,
        profiles: [RelayProfile] = [],
        selectedID: UUID? = nil,
        homeMigrations: [UUID: HomeMigrationJournal] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedID = selectedID
        self.homeMigrations = homeMigrations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, selectedID, homeMigrations, standardProfiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        profiles = try values.decode([RelayProfile].self, forKey: .profiles)
        // Keep direct entries out of the legacy array: older builds ignore
        // them instead of treating an upstream endpoint as a fork relay.
        profiles += try values.decodeIfPresent([RelayProfile].self, forKey: .standardProfiles) ?? []
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        homeMigrations = try values.decodeIfPresent(
            [UUID: HomeMigrationJournal].self,
            forKey: .homeMigrations
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(profiles.filter { $0.standardProfile == nil }, forKey: .profiles)
        try values.encode(profiles.filter { $0.standardProfile != nil }, forKey: .standardProfiles)
        try values.encodeIfPresent(selectedID, forKey: .selectedID)
        try values.encode(homeMigrations, forKey: .homeMigrations)
    }

    var selectedProfile: RelayProfile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    mutating func upsert(_ profile: RelayProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Removing the active profile clears the selection. Promoting a
    /// neighbour would silently retarget the user's next Connect.
    mutating func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        homeMigrations.removeValue(forKey: id)
        if selectedID == id {
            selectedID = nil
        }
    }

    func transportMode(for profileID: UUID) -> AppleTransportMode {
        if profiles.first(where: { $0.id == profileID })?.standardProfile != nil { return .standard }
        return homeMigrations[profileID]?.selectedMode == .home ? .home : .legacy
    }
}
