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
    let onResendUnconfirmedTurn: () -> Void
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
        homeCommandEventCount: Int = 0
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
        self.onResendUnconfirmedTurn = onResendUnconfirmedTurn
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
                unconfirmedTurnNotice(text: unconfirmedTurnText)
            }

            if let homeBridgeState {
                homeStatusNotice(bridge: homeBridgeState)
            }

            Spacer(minLength: 20)

            AmbientVisualizer(
                presentation: presentation,
                doorwayState: doorwayState
            )

            VStack(spacing: 8) {
                Text(doorwayStatusLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(doorwayTint)
                    .accessibilityHidden(true)

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
        .background {
            HermesVisualTokens.canvas
                .ignoresSafeArea()
        }
        .overlay {
            LinearGradient(
                colors: [
                    doorwayTint.opacity(0.12),
                    Color.clear,
                    doorwayTint.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
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
    private func unconfirmedTurnNotice(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(HermesVisualTokens.attention)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.footnote)
                    .lineLimit(2)
                Text("Not confirmed by Hermes. It was not sent again automatically.")
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }

            Spacer(minLength: 8)

            Button("Resend", action: onResendUnconfirmedTurn)
                .disabled(!connectionState.isConnected)
                .font(.footnote.weight(.semibold))
                .relayGlassProminentButtonStyle()
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(profileName ?? "No Profile selected")
                        .font(.subheadline.weight(.semibold))
                    Text("Hermes Profile · \(doorwayState.statusLabel) · \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Hermes Profile \(profileName ?? "not selected"), \(doorwayState.statusLabel), session duration \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: context.date))"
            )
        }
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

private struct AmbientVisualizer: View {
    let presentation: AmbientHUDPresentation
    let doorwayState: ConversationDoorwayState
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
