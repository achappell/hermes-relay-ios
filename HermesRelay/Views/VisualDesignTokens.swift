import SwiftUI

/// Semantic colors for the Night Console visual system.
///
/// The named colors have light and dark appearances in Assets.xcassets. Views
/// should use these roles rather than choosing a system color for each state;
/// that keeps the state language consistent across the conversation shell,
/// voice controls, and transcript rail.
enum HermesVisualTokens {
    static let canvas = Color("HermesCanvas")
    static let consoleSurface = Color("HermesConsoleSurface")
    static let panel = Color("HermesPanel")
    static let raisedPanel = Color("HermesRaisedPanel")
    static let primaryInk = Color("HermesPrimaryInk")
    static let secondaryInk = Color("HermesSecondaryInk")

    static let live = Color("HermesLive")
    static let attention = Color("HermesAttention")
    static let identity = Color("HermesIdentity")
    static let unavailable = Color("HermesUnavailable")

    static let hairline = secondaryInk.opacity(0.22)
    static let liveWash = live.opacity(0.16)
    static let attentionWash = attention.opacity(0.16)
    static let identityWash = identity.opacity(0.16)
    static let unavailableWash = unavailable.opacity(0.16)

    static func color(for state: ConversationDoorwayState) -> Color {
        switch state {
        case .unconfigured, .disconnected:
            return attention
        case .connecting, .reconnecting:
            return identity
        case .connected:
            return live
        case .unavailable:
            return unavailable
        }
    }

    static func color(for mode: AmbientHUDMode) -> Color {
        switch mode {
        case .idle, .complete:
            return live
        case .listening, .transcribing, .speaking:
            return live
        case .thinking, .buffering:
            return identity
        case .interrupted:
            return attention
        case .failed:
            return unavailable
        }
    }
}
