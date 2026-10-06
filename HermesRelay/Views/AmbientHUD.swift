import Foundation
import Observation
import SwiftUI

enum AmbientHUDMode: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case buffering
    case speaking
    case complete
    case interrupted
    case failed

    init(voiceState: VoiceState) {
        switch voiceState {
        case .idle:
            self = .idle
        case .listening:
            self = .listening
        case .transcribing:
            self = .transcribing
        case .thinking:
            self = .thinking
        case .buffering:
            self = .buffering
        case .speaking:
            self = .speaking
        case .complete:
            self = .complete
        case .interrupted:
            self = .interrupted
        case .failed:
            self = .failed
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .thinking:
            return "Thinking"
        case .buffering:
            return "Buffering"
        case .speaking:
            return "Speaking"
        case .complete:
            return "Complete"
        case .interrupted:
            return "Interrupted"
        case .failed:
            return "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "mic"
        case .listening:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .thinking:
            return "ellipsis"
        case .buffering:
            return "arrow.down.circle"
        case .speaking:
            return "speaker.wave.2.fill"
        case .complete:
            return "checkmark.circle"
        case .interrupted:
            return "pause.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}

enum ConversationDoorwayState: Equatable, Sendable {
    case unconfigured
    case connecting
    case connected
    case reconnecting(attempt: Int, of: Int)
    case disconnected
    case unavailable(String)

    init(connectionState: ConnectionState, profileName: String?) {
        switch connectionState {
        case .disconnected:
            self = profileName == nil ? .unconfigured : .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reconnecting(let attempt, let total):
            self = .reconnecting(attempt: attempt, of: total)
        case .failed(let message):
            self = profileName == nil ? .unconfigured : .unavailable(message)
        }
    }

    var statusLabel: String {
        switch self {
        case .unconfigured:
            return "Not configured"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .disconnected:
            return "Disconnected"
        case .unavailable:
            return "Unavailable"
        }
    }

    var recoveryMessage: String? {
        switch self {
        case .unconfigured:
            return "Configure a Hermes relay profile to begin."
        case .connecting:
            return nil
        case .connected:
            return nil
        case .reconnecting:
            return "The connection is being restored. Voice input is paused."
        case .disconnected:
            return "Connect to the selected Hermes relay to begin."
        case .unavailable(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The selected Hermes relay is unavailable." : trimmed
        }
    }

    var primaryActionTitle: String? {
        switch self {
        case .unconfigured:
            return "Configure relay"
        case .disconnected:
            return "Connect"
        case .unavailable:
            return "Retry"
        case .connecting, .connected, .reconnecting:
            return nil
        }
    }

    var isVoiceAvailable: Bool {
        self == .connected
    }
}

enum AmbientCaptionSource: Equatable, Sendable {
    case user
    case hermes

    var label: String {
        switch self {
        case .user:
            return "You"
        case .hermes:
            return "Hermes"
        }
    }
}

struct AmbientHUDPresentation: Equatable, Sendable {
    let mode: AmbientHUDMode
    let isHandsFreeArmed: Bool
    let failureMessage: String?
    let failureAction: VoiceFailureAction?
    let caption: String?
    let captionSource: AmbientCaptionSource?
    let intensity: Double

    init(
        voiceState: VoiceState,
        activity: AudioActivitySnapshot,
        provisionalText: String,
        messages: [TranscriptMessage],
        isHandsFreeArmed: Bool = false
    ) {
        mode = AmbientHUDMode(voiceState: voiceState)
        self.isHandsFreeArmed = isHandsFreeArmed
        failureMessage = voiceState.failure?.message
        failureAction = voiceState.failure?.action

        let latestUserText = messages.reversed()
            .first { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .text
        let latestHermesText = messages.reversed()
            .first { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .text
        let liveText = provisionalText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .listening, .transcribing:
            caption = liveText.isEmpty ? latestUserText : liveText
            captionSource = caption == nil ? nil : .user
        case .thinking, .buffering, .speaking, .complete:
            if let latestHermesText {
                caption = latestHermesText
                captionSource = .hermes
            } else {
                caption = latestUserText
                captionSource = caption == nil ? nil : .user
            }
        case .idle, .interrupted, .failed:
            caption = nil
            captionSource = nil
        }

        switch mode {
        case .listening, .transcribing:
            intensity = max(0.12, Double(activity.microphoneLevel))
        case .speaking, .buffering:
            intensity = activity.playbackActive
                ? max(0.12, Double(activity.playbackLevel))
                : 0.18
        case .complete:
            intensity = 0.10
        case .thinking:
            intensity = 0.24
        case .interrupted:
            intensity = 0.34
        case .idle:
            intensity = 0.08
        case .failed:
            intensity = 0.10
        }
    }

    var statusLabel: String {
        if mode == .idle, isHandsFreeArmed {
            return "Listening for speech"
        }
        return mode.label
    }

    var emptyCaption: String {
        if mode == .idle {
            return isHandsFreeArmed ? "Speak to begin" : "Tap the microphone to begin"
        }
        return mode.label
    }

    var accessibilityLabel: String {
        "Hermes " + statusLabel.lowercased()
    }
}

enum SessionDurationFormatter {
    static func string(startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "00:00" }
        return string(elapsed: max(0, now.timeIntervalSince(startedAt)))
    }

    static func string(elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
@Observable
final class AmbientHUDModel {
    private(set) var snapshot = AudioActivitySnapshot.safe
    private var observationTask: Task<Void, Never>?

    func start(observing activityStore: AudioActivityStore) {
        guard observationTask == nil else { return }

        observationTask = Task { [weak self] in
            let snapshots = await activityStore.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

}

/// The orb is drawn at a fixed 260 pt. This lets it give up height — down to
/// 60% scale — when the screen is short, so the status block, the orb and the
/// live transcript fit between the top bar and the bottom bar before the HUD
/// has to scroll. The scaled drawing keeps its own hit area and accessibility.
private struct CompressibleOrb<Content: View>: View {
    private static var drawnSize: CGFloat { 260 }
    private static var minimumScale: CGFloat { 0.6 }
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, max(Self.minimumScale, proxy.size.height / Self.drawnSize))
            content
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(
            minHeight: Self.drawnSize * Self.minimumScale,
            maxHeight: Self.drawnSize
        )
    }
}

/// Sizes its one child to the scroll viewport when the child's smallest
/// layout fits, and otherwise to that smallest layout, so a scroll view
/// around it scrolls only once the content can no longer compress. Plain
/// `frame(minHeight:)` hands the child its natural height, which would defeat
/// the compression above.
struct ViewportFillLayout: Layout {
    var viewportHeight: CGFloat

    /// A child's size is not monotonic in the height it is proposed — flexible
    /// rows can claim more than a smaller proposal left them — so the smallest
    /// layout measured at zero height can still overflow when it is used as
    /// the frame. Grow the proposal until the child fits inside it.
    private func fittedHeight(of child: LayoutSubview, width: CGFloat) -> CGFloat {
        var height = max(
            viewportHeight,
            child.sizeThatFits(ProposedViewSize(width: width, height: 0)).height
        )
        for _ in 0..<4 {
            let needed = child.sizeThatFits(ProposedViewSize(width: width, height: height)).height
            if needed <= height { break }
            height = needed
        }
        return height
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        return CGSize(width: width, height: fittedHeight(of: child, width: width))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct AmbientHUDView: View {
    @Environment(\.openURL) private var openURL
    let presentation: AmbientHUDPresentation
    let connectionState: ConnectionState
    let sessionStartedAt: Date?
    let profileName: String?
    let transcriptMessages: [TranscriptMessage]
    let provisionalText: String
    let isResponseActive: Bool
    let activeAssistantID: UUID?
    let voiceCoordinator: VoiceSessionCoordinator?
    let speechTimings: [SpeechTiming]
    let playbackDuration: TimeInterval?
    let playbackPosition: TimeInterval?
    let isPlaybackDurationFinal: Bool
    let hasTranscript: Bool
    let canConfigure: Bool
    let unconfirmedTurnText: String?
    let canContinueWithoutResendingHomeTurn: Bool
    let onResendUnconfirmedTurn: () -> Void
    let onContinueWithoutResendingHomeTurn: () -> Void
    let onConfigure: () -> Void
    let onConnect: () -> Void
    let onShowHistory: () -> Void
    let settingsURL: URL?
    let homeBridgeState: HomeBridgeState?
    let homeRouteState: HomeRouteState?
    let homeTurnDeliveryState: HomeTurnDeliveryState?
    let homeAudioState: HomeAudioState?
    let homeTimingCapability: HomeTimingCapability?
    let pendingHomePromptKind: HomeStructuredPromptKind?
    let homeCommandEventCount: Int
    /// The current Home client session's title; nil when unnamed or unknown.
    let homeSessionTitle: String?
    /// Opens the Sessions sheet; nil when the profile has no client sessions.
    let onShowSessions: (() -> Void)?

    init(
        presentation: AmbientHUDPresentation,
        connectionState: ConnectionState,
        sessionStartedAt: Date?,
        profileName: String? = nil,
        transcriptMessages: [TranscriptMessage],
        provisionalText: String,
        isResponseActive: Bool,
        activeAssistantID: UUID?,
        voiceCoordinator: VoiceSessionCoordinator?,
        speechTimings: [SpeechTiming],
        playbackDuration: TimeInterval?,
        playbackPosition: TimeInterval?,
        isPlaybackDurationFinal: Bool,
        hasTranscript: Bool,
        canConfigure: Bool,
        unconfirmedTurnText: String?,
        onResendUnconfirmedTurn: @escaping () -> Void,
        canContinueWithoutResendingHomeTurn: Bool = false,
        onContinueWithoutResendingHomeTurn: @escaping () -> Void = {},
        onConfigure: @escaping () -> Void,
        onConnect: @escaping () -> Void,
        onShowHistory: @escaping () -> Void,
        settingsURL: URL? = nil,
        homeBridgeState: HomeBridgeState? = nil,
        homeRouteState: HomeRouteState? = nil,
        homeTurnDeliveryState: HomeTurnDeliveryState? = nil,
        homeAudioState: HomeAudioState? = nil,
        homeTimingCapability: HomeTimingCapability? = nil,
        pendingHomePromptKind: HomeStructuredPromptKind? = nil,
        homeCommandEventCount: Int = 0,
        homeSessionTitle: String? = nil,
        onShowSessions: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.connectionState = connectionState
        self.sessionStartedAt = sessionStartedAt
        self.profileName = profileName
        self.transcriptMessages = transcriptMessages
        self.provisionalText = provisionalText
        self.isResponseActive = isResponseActive
        self.activeAssistantID = activeAssistantID
        self.voiceCoordinator = voiceCoordinator
        self.speechTimings = speechTimings
        self.playbackDuration = playbackDuration
        self.playbackPosition = playbackPosition
        self.isPlaybackDurationFinal = isPlaybackDurationFinal
        self.hasTranscript = hasTranscript
        self.canConfigure = canConfigure
        self.unconfirmedTurnText = unconfirmedTurnText
        self.canContinueWithoutResendingHomeTurn = canContinueWithoutResendingHomeTurn
        self.onResendUnconfirmedTurn = onResendUnconfirmedTurn
        self.onContinueWithoutResendingHomeTurn = onContinueWithoutResendingHomeTurn
        self.onConfigure = onConfigure
        self.onConnect = onConnect
        self.onShowHistory = onShowHistory
        self.settingsURL = settingsURL
        self.homeBridgeState = homeBridgeState
        self.homeRouteState = homeRouteState
        self.homeTurnDeliveryState = homeTurnDeliveryState
        self.homeAudioState = homeAudioState
        self.homeTimingCapability = homeTimingCapability
        self.pendingHomePromptKind = pendingHomePromptKind
        self.homeCommandEventCount = homeCommandEventCount
        self.homeSessionTitle = homeSessionTitle
        self.onShowSessions = onShowSessions
    }

    private var liveProvisionalText: String {
        voiceCoordinator?.provisionalText ?? provisionalText
    }

    private var doorwayState: ConversationDoorwayState {
        ConversationDoorwayState(
            connectionState: connectionState,
            profileName: profileName
        )
    }

    /// The orb is the voice control only when connected; otherwise it keeps
    /// showing the connection state and is not tappable.
    private var orbCoordinator: VoiceSessionCoordinator? {
        doorwayState == .connected ? voiceCoordinator : nil
    }

    /// State, then what a tap on the orb will do: "Ready · Tap to talk".
    private var orbStatusLine: String {
        guard let orbCoordinator else { return doorwayStatusLabel }
        let action = VoiceControlInteractionPolicy.orbAction(
            state: orbCoordinator.state,
            isHandsFreeArmed: orbCoordinator.isHandsFreeArmed,
            isHandsFreeCaptureActive: orbCoordinator.isHandsFreeCaptureActive
        )
        return "\(doorwayStatusLabel) · \(action.prompt)"
    }

    private var doorwayStatusLabel: String {
        doorwayState == .connected ? presentation.statusLabel : doorwayState.statusLabel
    }

    private var doorwayTint: Color {
        HermesVisualTokens.color(for: doorwayState)
    }

    private var doorwayEmptyCaption: String {
        switch doorwayState {
        case .unconfigured:
            return "Configure a relay to begin"
        case .connecting:
            return "Connecting to Hermes…"
        case .connected:
            return presentation.emptyCaption
        case .reconnecting:
            return "Waiting for Hermes to reconnect"
        case .disconnected:
            return "Connect to the selected relay to begin"
        case .unavailable:
            return "Retry when the relay is available"
        }
    }

    private var showsCachedContextNotice: Bool {
        !connectionState.isConnected && hasTranscript
    }

    @MainActor
    static func settingsRecoveryURL(
        for presentation: AmbientHUDPresentation,
        suppliedURL: URL?
    ) -> URL? {
        guard presentation.failureAction == .openSettings else { return nil }
        return suppliedURL
    }

    @MainActor
    static func openSettingsAction(
        url: URL,
        openURL: OpenURLAction
    ) -> () -> Void {
        { openURL(url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader

            if showsCachedContextNotice {
                cachedContextNotice
            }

            if let unconfirmedTurnText {
                unconfirmedTurnNotice(
                    text: unconfirmedTurnText,
                    canContinueWithoutResending: canContinueWithoutResendingHomeTurn
                )
            }

            if let homeBridgeState {
                homeStatusNotice(bridge: homeBridgeState)
            }

            Spacer(minLength: 20)

            CompressibleOrb {
                if let orbCoordinator {
                    VoiceOrbButton(
                        coordinator: orbCoordinator,
                        presentation: presentation,
                        doorwayState: doorwayState,
                        statusLabel: doorwayStatusLabel
                    )
                } else {
                    AmbientVisualizer(
                        presentation: presentation,
                        doorwayState: doorwayState
                    )
                }
            }

            VStack(spacing: 8) {
                Text(orbStatusLine)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(doorwayTint)
                    .accessibilityHidden(true)

                if let orbCoordinator, orbCoordinator.state.isCaptureActive,
                   !orbCoordinator.isHandsFreeArmed {
                    Button("Cancel") {
                        Task { await orbCoordinator.cancelCapture() }
                    }
                    .font(.footnote.weight(.medium))
                    .relayGlassButtonStyle()
                    .accessibilityHint("Stops listening without sending.")
                }

                #if os(iOS)
                if let orbCoordinator {
                    HandsFreePill(coordinator: orbCoordinator)
                }
                #endif

                if let recoveryMessage = doorwayState.recoveryMessage {
                    doorwayRecoveryNotice(message: recoveryMessage)
                }

                if let failureMessage = presentation.failureMessage {
                    failureNotice(message: failureMessage)
                }
            }

            Spacer(minLength: 20)

            captionArea
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 900, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var cachedContextNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(HermesVisualTokens.attention)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cached conversation")
                    .font(.footnote.weight(.semibold))
                Text("Saved locally; not live while Hermes is unavailable.")
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Cached conversation. Saved locally; not live while Hermes is unavailable."
        )
    }

    private func failureNotice(message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(HermesVisualTokens.secondaryInk)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("voice-failure-message")

            if let recoveryURL = Self.settingsRecoveryURL(
                for: presentation,
                suppliedURL: settingsURL
            ) {
                Button(
                    "Open Settings",
                    action: Self.openSettingsAction(url: recoveryURL, openURL: openURL)
                )
                .font(.footnote.weight(.semibold))
                .relayGlassButtonStyle()
                .accessibilityIdentifier("open-settings-button")
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
    }

    private func doorwayRecoveryNotice(message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(HermesVisualTokens.secondaryInk)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("doorway-recovery-message")

            if doorwayState != .unconfigured || canConfigure {
                if let actionTitle = doorwayState.primaryActionTitle {
                    Button(actionTitle, action: performDoorwayAction)
                        .font(.footnote.weight(.semibold))
                        .relayGlassProminentButtonStyle()
                        .accessibilityIdentifier("doorway-primary-action")
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
    }

    private func performDoorwayAction() {
        switch doorwayState {
        case .unconfigured:
            onConfigure()
        case .disconnected, .unavailable:
            onConnect()
        case .connecting, .connected, .reconnecting:
            break
        }
    }

    /// A turn that was in flight when the transport died is never replayed
    /// automatically: Hermes may already have received it. Show what it was
    /// and let the sending be a deliberate act.
    private func unconfirmedTurnNotice(
        text: String,
        canContinueWithoutResending: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(HermesVisualTokens.attention)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.footnote)
                    .lineLimit(2)
                Text(
                    canContinueWithoutResending
                        ? "Home has no active turn. Its reply may not have reached this app; it was not resent."
                        : "Not confirmed by Hermes. It was not sent again automatically."
                )
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Resend", action: onResendUnconfirmedTurn)
                    .disabled(!connectionState.isConnected)
                    .font(.footnote.weight(.semibold))
                    .relayGlassProminentButtonStyle()
                if canContinueWithoutResending {
                    Button("Continue without resending", action: onContinueWithoutResendingHomeTurn)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("continue-without-resending-unconfirmed-turn")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unconfirmed turn, \(text). It was not sent again automatically.")
    }

    private func homeStatusNotice(bridge: HomeBridgeState) -> some View {
        let tint = bridge.isReady
            ? HermesVisualTokens.live
            : bridge.displayReason == nil
                ? HermesVisualTokens.secondaryInk
                : HermesVisualTokens.unavailable

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: bridge.isReady ? "house.fill" : "house")
                Text("Home bridge · \(bridge.displayLabel)")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
            }

            if let homeRouteState {
                Text("Route · \(homeRouteState.displayLabel)")
            }
            if let homeTurnDeliveryState,
               homeTurnDeliveryState != .idle {
                Text("Delivery · \(homeTurnDeliveryState.displayLabel)")
            }
            if let homeAudioState,
               homeAudioState != .notRequested {
                Text("Audio · \(homeAudioState.displayLabel)")
            }
            if homeTimingCapability == .absent {
                Text("Timing · Absent in the pinned Standard baseline")
            }
            if let pendingHomePromptKind {
                Text("Structured request · \(pendingHomePromptKind.displayLabel)")
            }
            if homeCommandEventCount > 0 {
                Text("Command events · \(homeCommandEventCount)")
            }
            if let reason = bridge.displayReason {
                Text("Reason · \(reason)")
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-bridge-status")
        .accessibilityLabel(
            "Home bridge \(bridge.displayLabel), \(homeRouteState?.displayLabel ?? "route not attempted")"
        )
    }

    private var sessionHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionState.statusColor)
                    .frame(width: 8, height: 8)

                if let onShowSessions {
                    Button(action: onShowSessions) {
                        headerLabels(now: context.date, showsSession: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Conversation \(homeSessionTitle ?? "untitled"), Hermes Profile \(profileName ?? "not selected"), \(doorwayState.statusLabel)"
                    )
                    .accessibilityHint("Shows this Profile's conversations")
                } else {
                    headerLabels(now: context.date, showsSession: false)
                }

                Spacer(minLength: 8)

                if canConfigure {
                    Button(action: onConfigure) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Configure relay")
                    .relayGlassButtonStyle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.consoleSurface)
            .modifier(SessionHeaderAccessibility(
                combines: onShowSessions == nil,
                label: "Hermes Profile \(profileName ?? "not selected"), \(doorwayState.statusLabel), session duration \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: context.date))"
            ))
        }
    }

    private func headerLabels(now: Date, showsSession: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profileName ?? "No Profile selected")
                .font(.subheadline.weight(.semibold))
            if showsSession {
                HStack(spacing: 4) {
                    Text(homeSessionTitle ?? "Untitled conversation")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(HermesVisualTokens.primaryInk)
            }
            Text("Hermes Profile · \(doorwayState.statusLabel) · \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: now))")
                .font(.caption)
                .foregroundStyle(HermesVisualTokens.secondaryInk)
        }
        .contentShape(Rectangle())
    }

    private var captionArea: some View {
        let projection = RecentTranscriptProjection(
            messages: transcriptMessages,
            provisionalText: liveProvisionalText,
            isResponseActive: isResponseActive,
            activeAssistantID: activeAssistantID
        )

        return VStack(spacing: 10) {
            if projection.entries.isEmpty {
                Text(doorwayEmptyCaption)
                    .font(.callout)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
                    .multilineTextAlignment(.center)
            } else {
                RecentTranscriptRail(
                    messages: transcriptMessages,
                    provisionalText: liveProvisionalText,
                    hasPersistedHistory: hasTranscript,
                    isResponseActive: isResponseActive,
                    activeAssistantID: activeAssistantID,
                    speechTimings: speechTimings,
                    playbackDuration: playbackDuration,
                    playbackPosition: playbackPosition,
                    isPlaybackDurationFinal: isPlaybackDurationFinal,
                    onShowHistory: onShowHistory
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .accessibilityElement(children: .contain)
    }
}

/// The HUD's full-bleed canvas and connection tint. It sits behind the
/// scrolling HUD rather than inside it, so the scroll view cannot clip it
/// short of the screen edges.
struct AmbientHUDBackdrop: View {
    let doorwayState: ConversationDoorwayState

    var body: some View {
        let tint = HermesVisualTokens.color(for: doorwayState)
        HermesVisualTokens.canvas
            .overlay {
                LinearGradient(
                    colors: [
                        tint.opacity(0.12),
                        Color.clear,
                        tint.opacity(0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The header reads as one element unless it holds the Sessions button,
/// which must stay separately focusable.
private struct SessionHeaderAccessibility: ViewModifier {
    let combines: Bool
    let label: String

    func body(content: Content) -> some View {
        if combines {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// The central orb as the voice control: tap to talk, tap to send, tap to
/// interrupt. Its glyph shows what a tap will do.
private struct VoiceOrbButton: View {
    let coordinator: VoiceSessionCoordinator
    let presentation: AmbientHUDPresentation
    let doorwayState: ConversationDoorwayState
    let statusLabel: String
    @State private var isActionInFlight = false

    private var action: VoiceOrbAction {
        VoiceControlInteractionPolicy.orbAction(
            state: coordinator.state,
            isHandsFreeArmed: coordinator.isHandsFreeArmed,
            isHandsFreeCaptureActive: coordinator.isHandsFreeCaptureActive
        )
    }

    private var isResponseActive: Bool {
        VoiceControlInteractionPolicy.isResponseActive(coordinator.state)
    }

    var body: some View {
        Button(action: perform) {
            AmbientVisualizer(
                presentation: presentation,
                doorwayState: doorwayState,
                actionImage: action.systemImage
            )
            .contentShape(Circle())
        }
        .buttonStyle(VoiceOrbPressStyle())
        .disabled(
            VoiceControlInteractionPolicy.isDisabled(
                isActionInFlight: isActionInFlight,
                state: coordinator.state,
                isHandsFreeArmed: coordinator.isHandsFreeArmed
            )
        )
        .accessibilityLabel("Voice")
        .accessibilityValue(statusLabel)
        .accessibilityHint(action.accessibilityHint)
        .accessibilityIdentifier("voice-orb")
    }

    private func perform() {
        guard !isActionInFlight || isResponseActive else { return }
        isActionInFlight = true
        Task { @MainActor in
            await VoiceControlInteractionPolicy.performPrimaryAction(on: coordinator)
            isActionInFlight = false
        }
    }
}

/// A slight press-in so the orb feels like the button it is.
private struct VoiceOrbPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AmbientVisualizer: View {
    let presentation: AmbientHUDPresentation
    let doorwayState: ConversationDoorwayState
    /// Set when the orb is the voice control: the glyph shows the action.
    var actionImage: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch doorwayState {
        case .connected:
            return HermesVisualTokens.color(for: presentation.mode)
        default:
            return HermesVisualTokens.color(for: doorwayState)
        }
    }

    private var isAnimated: Bool {
        doorwayState == .connected && presentation.mode.isAnimated
    }

    private var systemImage: String {
        if let actionImage { return actionImage }
        switch doorwayState {
        case .unconfigured:
            return "slider.horizontal.3"
        case .connecting, .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return presentation.mode.systemImage
        case .disconnected:
            return "bolt.horizontal.circle"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private var accessibilityLabel: String {
        "Hermes \(doorwayState == .connected ? presentation.statusLabel.lowercased() : doorwayState.statusLabel.lowercased())"
    }

    private var accessibilityValue: String {
        doorwayState == .connected ? presentation.statusLabel : doorwayState.statusLabel
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion || !isAnimated
        )) { context in
            let phase = reduceMotion || !isAnimated
                ? 0.0
                : (sin(context.date.timeIntervalSinceReferenceDate * 2.0) + 1.0) / 2.0
            let intensity = CGFloat(presentation.intensity)

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    ring(index: index, phase: phase, intensity: intensity)
                }

                coreOrb(phase: phase, intensity: intensity)

                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && isAnimated)
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHidden(actionImage != nil)
        }
    }

    private func ring(index: Int, phase: Double, intensity: CGFloat) -> some View {
        let opacity = 0.18 - Double(index) * 0.04
        let indexOffset = CGFloat(index) * 0.18
        let phaseOffset = CGFloat(phase) * (0.04 + CGFloat(index) * 0.02)
        let scale = 1.0 + indexOffset + intensity * 0.10 + phaseOffset

        return Circle()
            .stroke(tint.opacity(opacity), lineWidth: 1.5)
            .frame(width: 142, height: 142)
            .scaleEffect(scale)
    }

    private func coreOrb(phase: Double, intensity: CGFloat) -> some View {
        let diameter = 116 + intensity * 26 + CGFloat(phase) * 5

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        tint.opacity(0.88),
                        tint.opacity(0.22),
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: 100
                )
            )
            .frame(width: diameter, height: diameter)
            .shadow(
                color: tint.opacity(0.32),
                radius: 18 + intensity * 16
            )
    }
}

struct TranscriptHistoryView: View {
    let messages: [TranscriptMessage]
    @Environment(\.dismiss) private var dismiss
    private let exportFormatter = TranscriptExportFormatter()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // The newest message is what the reader came for. Anchoring is
            // resolved before the first frame, so the sheet opens at the
            // bottom rather than scrolling there afterwards — which matters
            // with a LazyVStack, whose trailing rows do not exist yet when a
            // scrollTo would run.
            .defaultScrollAnchor(.bottom)
            .navigationTitle("Conversation history")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            TranscriptClipboard.copy(exportFormatter.plainText(for: messages))
                        } label: {
                            Label("Copy conversation", systemImage: "doc.on.doc")
                        }

                        ShareLink(
                            item: exportFormatter.plainText(for: messages),
                            preview: SharePreview("Conversation (plain text)")
                        ) {
                            Label("Share plain text", systemImage: "doc.plaintext")
                        }

                        ShareLink(
                            item: exportFormatter.markdown(for: messages),
                            preview: SharePreview("Conversation (Markdown)")
                        ) {
                            Label("Share Markdown", systemImage: "number")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension AmbientHUDMode {
    var tint: Color {
        HermesVisualTokens.color(for: self)
    }

    var isAnimated: Bool {
        switch self {
        case .listening, .transcribing, .thinking, .buffering, .speaking:
            return true
        case .idle, .complete, .interrupted, .failed:
            return false
        }
    }
}

private extension ConnectionState {
    var statusColor: Color {
        switch self {
        case .connected:
            return HermesVisualTokens.live
        case .failed:
            return HermesVisualTokens.unavailable
        case .connecting, .reconnecting:
            return HermesVisualTokens.identity
        case .disconnected:
            return HermesVisualTokens.secondaryInk
        }
    }

}

#Preview("Ambient HUD") {
    AmbientHUDView(
        presentation: AmbientHUDPresentation(
            voiceState: .speaking,
            activity: AudioActivitySnapshot(
                microphoneLevel: 0,
                microphoneActivity: .silence,
                playbackLevel: 0.72,
                playbackActive: true
            ),
            provisionalText: "",
            messages: [TranscriptMessage(role: .assistant, text: "The ambient HUD is alive.")]
        ),
        connectionState: .connected,
        sessionStartedAt: Date().addingTimeInterval(-252),
        transcriptMessages: [TranscriptMessage(role: .assistant, text: "The ambient HUD is alive and the transcript stays readable while I continue speaking.")],
        provisionalText: "",
        isResponseActive: false,
        activeAssistantID: nil,
        voiceCoordinator: nil,
        speechTimings: [],
        playbackDuration: nil,
        playbackPosition: nil,
        isPlaybackDurationFinal: false,
        hasTranscript: true,
        canConfigure: true,
        unconfirmedTurnText: "Did this one reach Hermes?",
        onResendUnconfirmedTurn: {},
        onConfigure: {},
        onConnect: {},
        onShowHistory: {}
    )
}
