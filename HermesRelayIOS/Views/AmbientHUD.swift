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
        settingsURL: URL? = nil
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
    }

    private var liveProvisionalText: String {
        voiceCoordinator?.provisionalText ?? provisionalText
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

            Spacer(minLength: 20)

            AmbientVisualizer(presentation: presentation)

            VStack(spacing: 8) {
                Text(presentation.statusLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(presentation.mode.tint)
                    .accessibilityHidden(true)

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
            LinearGradient(
                colors: [
                    presentation.mode.tint.opacity(0.12),
                    Color.clear,
                    presentation.mode.tint.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
    }

    private var cachedContextNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cached conversation")
                    .font(.footnote.weight(.semibold))
                Text("Saved locally; not live while Hermes is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayGlass(cornerRadius: 20)
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
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
    }

    /// A turn that was in flight when the transport died is never replayed
    /// automatically: Hermes may already have received it. Show what it was
    /// and let the sending be a deliberate act.
    private func unconfirmedTurnNotice(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.footnote)
                    .lineLimit(2)
                Text("Not confirmed by Hermes. It was not sent again automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .relayGlass(cornerRadius: 20)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unconfirmed turn, \(text). It was not sent again automatically.")
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
                    Text("Hermes Profile · \(connectionState.label) · \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if !connectionState.isConnected {
                    Button(connectionState.connectButtonTitle, action: onConnect)
                        .disabled(connectionState == .connecting || connectionState.isReconnecting)
                        .font(.footnote.weight(.semibold))
                        .relayGlassProminentButtonStyle()
                }

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
            .relayGlass(cornerRadius: 20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Hermes Profile \(profileName ?? "not selected"), \(connectionState.label), session duration \(SessionDurationFormatter.string(startedAt: sessionStartedAt, now: context.date))"
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
                Text(presentation.emptyCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        .relayGlass(cornerRadius: 22)
        .accessibilityElement(children: .contain)
    }
}

private struct AmbientVisualizer: View {
    let presentation: AmbientHUDPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion || !presentation.mode.isAnimated
        )) { context in
            let phase = reduceMotion || !presentation.mode.isAnimated
                ? 0.0
                : (sin(context.date.timeIntervalSinceReferenceDate * 2.0) + 1.0) / 2.0
            let intensity = CGFloat(presentation.intensity)

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    ring(index: index, phase: phase, intensity: intensity)
                }

                coreOrb(phase: phase, intensity: intensity)

                Image(systemName: presentation.mode.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && presentation.mode.isAnimated)
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.statusLabel)
        }
    }

    private func ring(index: Int, phase: Double, intensity: CGFloat) -> some View {
        let opacity = 0.18 - Double(index) * 0.04
        let indexOffset = CGFloat(index) * 0.18
        let phaseOffset = CGFloat(phase) * (0.04 + CGFloat(index) * 0.02)
        let scale = 1.0 + indexOffset + intensity * 0.10 + phaseOffset

        return Circle()
            .stroke(presentation.mode.tint.opacity(opacity), lineWidth: 1.5)
            .frame(width: 142, height: 142)
            .scaleEffect(scale)
    }

    private func coreOrb(phase: Double, intensity: CGFloat) -> some View {
        let diameter = 116 + intensity * 26 + CGFloat(phase) * 5

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        presentation.mode.tint.opacity(0.88),
                        presentation.mode.tint.opacity(0.22),
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: 100
                )
            )
            .frame(width: diameter, height: diameter)
            .shadow(
                color: presentation.mode.tint.opacity(0.32),
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
        switch self {
        case .idle:
            return .secondary
        case .listening:
            return .accentColor
        case .transcribing:
            return .teal
        case .thinking:
            return .purple
        case .buffering:
            return .indigo
        case .speaking:
            return .orange
        case .complete:
            return .green
        case .interrupted:
            return .yellow
        case .failed:
            return .red
        }
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
            return .green
        case .failed:
            return .red
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .secondary
        }
    }

    var connectButtonTitle: String {
        switch self {
        case .failed:
            return "Retry"
        case .reconnecting:
            return "Reconnecting…"
        case .disconnected, .connecting:
            return "Connect"
        case .connected:
            return "Connected"
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
