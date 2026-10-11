import Foundation

/// Which conversation layout shows (IOS-UX-F7). The app opens in the voice
/// view; the typing view puts the transcript and composer first.
enum ConversationViewMode: Equatable, Sendable {
    case voice
    case typing
}

enum ConversationViewModeEvent: Equatable, Sendable {
    /// The composer gained or lost focus.
    case composerFocusChanged(isFocused: Bool)
    /// The small voice control was activated (tap or keyboard shortcut).
    case voiceControlActivated
    /// The voice state changed. Capture starting by any route (a hands-free
    /// wake, or a future voice shortcut) is an explicit voice action.
    case voiceStateChanged(VoiceState)
}

/// The mode is its own state and focus is only a trigger. Deriving the mode
/// from focus would flip the view whenever the keyboard goes away, which
/// turns reading the transcript into an accidental switch (owner decision
/// 2026-10-07, options (a) and (d)). The typing view therefore leaves only
/// on an explicit voice action, never on blur, scroll or idle time.
enum ConversationViewModeReducer {
    static let launchMode = ConversationViewMode.voice

    static func reduce(
        _ mode: ConversationViewMode,
        _ event: ConversationViewModeEvent
    ) -> ConversationViewMode {
        switch event {
        case .composerFocusChanged(let isFocused):
            return isFocused ? .typing : mode
        case .voiceControlActivated:
            return .voice
        case .voiceStateChanged(let state):
            return state.isCaptureActive ? .voice : mode
        }
    }
}
