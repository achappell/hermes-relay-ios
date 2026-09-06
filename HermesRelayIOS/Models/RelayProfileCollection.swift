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

    init(
        schemaVersion: Int = RelayProfileCollection.currentSchemaVersion,
        profiles: [RelayProfile] = [],
        selectedID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedID = selectedID
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
        if selectedID == id {
            selectedID = nil
        }
    }
}
