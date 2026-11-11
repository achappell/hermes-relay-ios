import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum DuoScreen: Equatable {
    case unavailable, outer, inner
}

struct DuoHingeObserver: ViewModifier {
    @Binding var screen: DuoScreen
    @Binding var fullyOpen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                guard let hinge = context.hinge else {
                    fullyOpen = false
                    screen = .unavailable
                    return
                }
                screen = hinge.status == .closed ? .outer : .inner
                fullyOpen = hinge.status == .fullyOpen
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
private struct DuoDivisionObserver: ViewModifier {
    @Binding var division: CGRect

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onGeometryChange(for: CGRect.self) { proxy in
                proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame ?? .zero
            } action: { division = $0 }
        } else {
            content
        }
        #else
        content
        #endif
    }
}


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
/// Width-driven layout for regular devices and the iOS 26 fallback. On a
/// detected hinge, iOS 27.1+ instead uses the Duo workspace below.
enum AmbientHUDLayoutMode: Equatable {
    case compact
    case expanded

    static let expandedMinimumWidth: CGFloat = 600

    static func mode(for width: CGFloat) -> Self {
        width >= expandedMinimumWidth ? .expanded : .compact
    }
}

/// Places the voice stage and the transcript card: stacked when compact,
/// side by side when expanded. Both are the same two subviews in one layout
/// container, so a resize re-places them rather than rebuilding them, and the
/// transcript's follow/reveal state survives. Because it is a `Layout` and not
/// a `GeometryReader`, it still reports a real minimum height to
/// `ViewportFillLayout`, so large type scrolls instead of clipping.
struct AdaptiveVoiceLayout: Layout {
    private static let columnSpacing: CGFloat = 24

    private func arrangement(forWidth width: CGFloat?) -> AnyLayout {
        guard let width, AmbientHUDLayoutMode.mode(for: width) == .expanded else {
            return AnyLayout(VStackLayout(spacing: 0))
        }
        return AnyLayout(HStackLayout(alignment: .center, spacing: Self.columnSpacing))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let layout = arrangement(forWidth: proposal.width)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &layoutCache)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = arrangement(forWidth: bounds.width)
        var layoutCache = layout.makeCache(subviews: subviews)
        layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &layoutCache)
    }
}


/// Shares the top row between the compact header and the full workspace
/// without replacing either subtree as the hinge changes posture.
struct DuoOpenChromeLayout: Layout {
    static let gap: CGFloat = 8

    static func headerWidth(for width: CGFloat) -> CGFloat {
        max(0, width * 0.44 - gap / 2)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 0
        let header = subviews[0].sizeThatFits(.init(width: Self.headerWidth(for: width), height: nil))
        let workspace = subviews[1].sizeThatFits(.init(width: width, height: proposal.height))
        return CGSize(width: width, height: max(header.height, workspace.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: Self.headerWidth(for: bounds.width), height: nil))
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: bounds.height))
    }
}

/// Places the same five state-bearing children in every Duo posture.
/// Moving the composer or transcript preserves their focus and follow state.
struct DuoWorkspaceLayout: Layout {
    let screen: DuoScreen
    let division: CGRect
    let primaryGuide: CGRect
    let secondaryGuide: CGRect
    let composerIdealHeight: CGFloat
    let hasTranscriptContent: Bool
    var openHeaderHeight: CGFloat = 0
    var openTrailingHeight: CGFloat = 0

    static func needsCompactVoice(screen: DuoScreen, division: CGRect, height: CGFloat) -> Bool {
        screen == .inner && !division.isEmpty && division.width >= division.height
            && height - division.maxY < 160
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 480)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let width = bounds.width
        let height = bounds.height
        let gap: CGFloat = 8
        let toggleHeight: CGFloat = 48
        let composerHeight = min(height * (hasTranscriptContent ? 0.45 : 0.8), composerIdealHeight)
        let actionHeight = min(height, subviews[3].sizeThatFits(.init(width: width, height: nil)).height)
        var voice = CGRect(x: 0, y: 0, width: width, height: height)
        var transcript = voice
        var composer = CGRect.zero
        var action = CGRect.zero
        let toggle = CGRect(x: 0, y: max(0, height - toggleHeight), width: width, height: toggleHeight)

        if screen == .outer {
            let bottom = max(0, toggle.minY - gap)
            voice.size.height = bottom
            action = CGRect(x: 0, y: max(0, bottom - actionHeight), width: width, height: actionHeight)
            composer = CGRect(x: 0, y: max(0, action.minY - composerHeight), width: width, height: composerHeight)
            transcript.size.height = max(0, composer.minY - gap)
        } else {
            let active = !division.isEmpty
            let vertical = active && division.height > division.width
            let horizontal = active && !vertical
            if vertical {
                let left = CGRect(x: 0, y: 0, width: max(0, division.minX), height: height)
                let right = CGRect(x: min(width, division.maxX), y: 0, width: max(0, width - division.maxX), height: height)
                // Layout coordinates mirror automatically in RTL.
                voice = left
                transcript = right
            } else if horizontal {
                transcript = CGRect(x: 0, y: 0, width: width, height: max(0, division.minY))
                voice = CGRect(x: 0, y: min(height, division.maxY), width: width, height: max(0, height - division.maxY))
            } else {
                let voiceWidth = max(0, width * 0.44 - gap / 2)
                let transcriptWidth = max(0, width - voiceWidth - gap)
                let voiceTop = min(height, openHeaderHeight)
                let transcriptTop = min(height, openTrailingHeight)
                voice = CGRect(x: 0, y: voiceTop, width: voiceWidth, height: max(0, height - voiceTop))
                transcript = CGRect(x: voiceWidth + gap, y: transcriptTop, width: transcriptWidth, height: max(0, height - transcriptTop))
            }
            // ArrangementView provides the system's actual panel bounds when
            // it has resolved the active division. Ignore stale measurements
            // while a fold/rotation is in flight.
            if active, !primaryGuide.isEmpty, !secondaryGuide.isEmpty {
                let guides = [primaryGuide, secondaryGuide]
                let container = CGRect(x: 0, y: 0, width: width, height: height)
                if vertical {
                    let ordered = guides.sorted { $0.minX < $1.minX }
                    if ordered[0].maxX <= division.minX + 1, ordered[1].minX >= division.maxX - 1,
                       guides.allSatisfy({ container.contains($0) }) {
                        voice = ordered[0]
                        transcript = ordered[1]
                    }
                } else if horizontal {
                    let ordered = guides.sorted { $0.minY < $1.minY }
                    if ordered[0].maxY <= division.minY + 1, ordered[1].minY >= division.maxY - 1,
                       guides.allSatisfy({ container.contains($0) }) {
                        transcript = ordered[0]
                        voice = ordered[1]
                    }
                }
            }
            let composerPanel = vertical ? voice : transcript
            let composerFraction: CGFloat = vertical || hasTranscriptContent ? 0.7 : 1
            let measured = min(composerPanel.height * composerFraction, composerIdealHeight)
            composer = CGRect(x: composerPanel.minX, y: max(composerPanel.minY, composerPanel.maxY - measured), width: composerPanel.width, height: measured)
            if vertical {
                voice.size.height = max(0, composer.minY - voice.minY - gap)
            } else {
                if Self.needsCompactVoice(screen: screen, division: division, height: height) {
                    action = CGRect(x: transcript.minX, y: max(transcript.minY, composer.minY - actionHeight), width: transcript.width, height: actionHeight)
                    transcript.size.height = max(0, action.minY - transcript.minY - gap)
                } else {
                    transcript.size.height = max(0, composer.minY - transcript.minY - gap)
                }
            }
        }

        for (index, rect) in [voice, transcript, composer, action, toggle].enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: max(0, rect.width), height: max(0, rect.height))
            )
        }
    }
}

#if os(iOS)
@available(iOS 27.1, *)
private struct DuoArrangementGuide: View {
    @Binding var primary: CGRect
    @Binding var secondary: CGRect

    var body: some View {
        ArrangementView {
            Color.clear.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("duo-workspace"))
            } action: { primary = $0 }
        } secondary: {
            Color.clear.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("duo-workspace"))
            } action: { secondary = $0 }
        }
        .arrangementViewStyle(.split)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

struct AmbientHUDView: View {
    @Environment(\.openURL) private var openURL
    @State private var outerTranscript = false
    @State private var division: CGRect = .zero
    @State private var guidePrimary: CGRect = .zero
    @State private var guideSecondary: CGRect = .zero
    @State private var duoComposerHeight: CGFloat = 100
    @State private var duoHeaderHeight: CGFloat = 82
    @State private var duoDisconnectHeight: CGFloat = 44
    @AccessibilityFocusState private var outerToggleFocused: Bool
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
    /// Which layout shows (IOS-UX-F7). Typing keeps the header and every
    /// notice, and swaps the orb and reply rail for the full transcript.
    let viewMode: ConversationViewMode
    /// Lets the conversation move screen-reader focus to the voice orb when
    /// the voice view returns.
    let orbAccessibilityFocus: AccessibilityFocusState<Bool>.Binding?
    /// Thinking text per turn (IOS-UX-F6) and how to open one.
    let thinkingTurns: [ThinkingTurn]
    let duoScreen: DuoScreen
    let duoFullyOpen: Bool
    let onDuoDisconnect: (() -> Void)?
    let isDuoDisconnectDisabled: Bool
    let duoViewportHeight: CGFloat
    let duoComposer: AnyView
    let onDuoTalkSelected: () -> Void
    let onOpenThinking: (UUID) -> Void

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
        onShowSessions: (() -> Void)? = nil,
        viewMode: ConversationViewMode = .voice,
        orbAccessibilityFocus: AccessibilityFocusState<Bool>.Binding? = nil,
        thinkingTurns: [ThinkingTurn] = [],
        duoScreen: DuoScreen = .unavailable,
        duoFullyOpen: Bool = false,
        onDuoDisconnect: (() -> Void)? = nil,
        isDuoDisconnectDisabled: Bool = false,
        duoViewportHeight: CGFloat = 600,
        duoComposer: AnyView = AnyView(EmptyView()),
        onDuoTalkSelected: @escaping () -> Void = {},
        onOpenThinking: @escaping (UUID) -> Void = { _ in }
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
        self.viewMode = viewMode
        self.orbAccessibilityFocus = orbAccessibilityFocus
        self.thinkingTurns = thinkingTurns
        self.duoScreen = duoScreen
        self.duoFullyOpen = duoFullyOpen
        self.onDuoDisconnect = onDuoDisconnect
        self.isDuoDisconnectDisabled = isDuoDisconnectDisabled
        self.duoViewportHeight = duoViewportHeight
        self.duoComposer = duoComposer
        self.onDuoTalkSelected = onDuoTalkSelected
        self.onOpenThinking = onOpenThinking
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
    /// While muted, "Muted" follows the state: "Speaking · Muted · Tap to interrupt".
    private var orbStatusLine: String {
        guard let orbCoordinator else { return doorwayStatusLabel }
        if duoScreen != .unavailable, orbCoordinator.isHandsFreeArmed,
           !orbCoordinator.state.isResponseActive {
            return doorwayStatusLabel
        }
        let action = VoiceControlInteractionPolicy.orbAction(
            state: orbCoordinator.state,
            isHandsFreeArmed: orbCoordinator.isHandsFreeArmed,
            isHandsFreeCaptureActive: orbCoordinator.isHandsFreeCaptureActive
        )
        return Self.orbStatusLine(
            statusLabel: doorwayStatusLabel,
            isMuted: orbCoordinator.isMuted,
            prompt: action.prompt
        )
    }

    nonisolated static func orbStatusLine(statusLabel: String, isMuted: Bool, prompt: String) -> String {
        isMuted ? "\(statusLabel) · Muted · \(prompt)" : "\(statusLabel) · \(prompt)"
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
        let layout = duoFullyOpen ? AnyLayout(DuoOpenChromeLayout()) : AnyLayout(VStackLayout(spacing: 0))
        layout {
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
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                duoHeaderHeight = $0
            }
            .zIndex(1)

            if duoScreen != .unavailable {
                duoContent
            } else if viewMode == .typing {
                typingContent
            } else {
                voiceContent
            }
        }
        .overlay(alignment: .topTrailing) {
            if duoFullyOpen, let onDuoDisconnect {
                Button(action: onDuoDisconnect) {
                    Text("Disconnect")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isDuoDisconnectDisabled)
                .accessibilityIdentifier("home-disconnect")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    duoDisconnectHeight = max(44, $0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 900, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var duoContent: some View {
        let hasTranscriptContent = !transcriptMessages.isEmpty || !liveProvisionalText.isEmpty
        let workspaceHeight = duoFullyOpen
            ? max(duoViewportHeight - 28, duoHeaderHeight + 160)
            : max(160, duoViewportHeight - duoHeaderHeight - 28)
        let compactVoice = DuoWorkspaceLayout.needsCompactVoice(
            screen: duoScreen, division: division, height: workspaceHeight
        )
        return DuoWorkspaceLayout(
            screen: duoScreen,
            division: division,
            primaryGuide: guidePrimary,
            secondaryGuide: guideSecondary,
            composerIdealHeight: duoComposerHeight,
            hasTranscriptContent: hasTranscriptContent,
            openHeaderHeight: duoFullyOpen ? duoHeaderHeight + 8 : 0,
            openTrailingHeight: duoFullyOpen && onDuoDisconnect != nil ? duoDisconnectHeight + 8 : 0
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    CompressibleOrb {
                        if let orbCoordinator {
                            VoiceOrbButton(
                                coordinator: orbCoordinator,
                                presentation: presentation,
                                doorwayState: doorwayState,
                                statusLabel: doorwayStatusLabel,
                                accessibilityFocus: orbAccessibilityFocus
                            )
                        } else {
                            AmbientVisualizer(presentation: presentation, doorwayState: doorwayState)
                        }
                    }
                    voiceControls
                }
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(doorwayState == .connected ? .top : .bottom)
            .opacity((duoScreen == .outer && outerTranscript) || compactVoice ? 0 : 1)
            .allowsHitTesting(!(duoScreen == .outer && outerTranscript) && !compactVoice)
            .accessibilityHidden((duoScreen == .outer && outerTranscript) || compactVoice)

            GeometryReader { proxy in
                captionArea
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .clipped()
            }
            .opacity(!hasTranscriptContent || (duoScreen == .outer && !outerTranscript) ? 0 : 1)
            .allowsHitTesting(hasTranscriptContent && (duoScreen != .outer || outerTranscript))
            .accessibilityHidden(!hasTranscriptContent || (duoScreen == .outer && !outerTranscript))

            GeometryReader { proxy in
                ScrollView {
                    duoComposer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            duoComposerHeight = max(44, $0)
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.top)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
            .opacity(duoScreen == .outer && !outerTranscript ? 0 : 1)
            .allowsHitTesting(duoScreen != .outer || outerTranscript)
            .accessibilityHidden(duoScreen == .outer && !outerTranscript)

            DuoTranscriptVoiceAction(coordinator: orbCoordinator, statusLabel: doorwayStatusLabel)
                .opacity((duoScreen == .outer && outerTranscript) || compactVoice ? 1 : 0)
                .allowsHitTesting((duoScreen == .outer && outerTranscript) || compactVoice)
                .accessibilityHidden(!(duoScreen == .outer && outerTranscript) && !compactVoice)

            if duoScreen == .outer {
                Picker("Conversation view", selection: $outerTranscript) {
                    Text("Talk").tag(false)
                    Text("Transcript").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityFocused($outerToggleFocused)
                .accessibilityIdentifier("duo-view-toggle")
            } else {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .modifier(DuoDivisionObserver(division: $division))
        .background {
            #if os(iOS)
            if #available(iOS 27.1, *) {
                DuoArrangementGuide(primary: $guidePrimary, secondary: $guideSecondary)
            }
            #endif
        }
        .coordinateSpace(name: "duo-workspace")
        .frame(height: workspaceHeight)
        .onChange(of: outerTranscript) { _, selected in
            if !selected { onDuoTalkSelected() }
            outerToggleFocused = true
            #if os(iOS)
            UIAccessibility.post(notification: .announcement, argument: selected ? "Transcript view" : "Talk view")
            #endif
        }
        .onChange(of: duoScreen) { _, screen in
            if screen == .outer && !outerTranscript { onDuoTalkSelected() }
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        AdaptiveVoiceLayout {
            VStack(spacing: 0) {
                Spacer(minLength: 20)

                CompressibleOrb {
                    if let orbCoordinator {
                        VoiceOrbButton(
                            coordinator: orbCoordinator,
                            presentation: presentation,
                            doorwayState: doorwayState,
                            statusLabel: doorwayStatusLabel,
                            accessibilityFocus: orbAccessibilityFocus
                        )
                    } else {
                        AmbientVisualizer(
                            presentation: presentation,
                            doorwayState: doorwayState
                        )
                    }
                }

                voiceControls

                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            captionArea
                .frame(maxWidth: .infinity)
        }
    }

    private var voiceControls: some View {
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

            if let orbCoordinator {
                HStack(spacing: 10) {
                    #if os(iOS)
                    HandsFreePill(coordinator: orbCoordinator)
                    #endif
                    MuteButton(coordinator: orbCoordinator)
                }
            }

            if let recoveryMessage = doorwayState.recoveryMessage {
                doorwayRecoveryNotice(message: recoveryMessage)
            }

            if let failureMessage = presentation.failureMessage {
                failureNotice(message: failureMessage)
            }
        }
    }

    /// The typing view: the transcript sits above the composer with the
    /// newest message at the bottom. The status line keeps "Muted" visible;
    /// the controls (Talk, Mute, Interrupt) sit by the composer (IOS-UX-F10).
    /// The recovery and failure notices stay reachable, as in the voice view.
    @ViewBuilder
    private var typingContent: some View {
        Text(Self.typingStatusLine(statusLabel: doorwayStatusLabel, isMuted: orbCoordinator?.isMuted ?? false))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(doorwayTint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .padding(.top, 4)

        if let recoveryMessage = doorwayState.recoveryMessage {
            doorwayRecoveryNotice(message: recoveryMessage)
        }

        if let failureMessage = presentation.failureMessage {
            failureNotice(message: failureMessage)
        }

        Spacer(minLength: 8)

        TypingTranscriptView(
            messages: transcriptMessages,
            thinkingTurns: thinkingTurns,
            onOpenThinking: onOpenThinking
        )
    }

    /// The typing view's status line: the state, then "Muted" while muted.
    nonisolated static func typingStatusLine(statusLabel: String, isMuted: Bool) -> String {
        isMuted ? "\(statusLabel) · Muted" : statusLabel
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
                combines: onShowSessions == nil && duoScreen == .unavailable,
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
            if let turn = ThinkingTranscriptOrdering.latestExchangeTurn(
                messages: transcriptMessages,
                turns: thinkingTurns
            ) {
                ThinkingRow(turn: turn) { onOpenThinking(turn.id) }
            }
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
                    showsStreamedReply: voiceCoordinator?.replyTextIsLive ?? false,
                    expandsToAvailableHeight: duoScreen != .unavailable,
                    onShowHistory: onShowHistory
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: duoScreen != .unavailable ? .infinity : nil)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .accessibilityElement(children: .contain)
    }
}

private struct DuoTranscriptVoiceAction: View {
    let coordinator: VoiceSessionCoordinator?
    let statusLabel: String
    @State private var inFlight = false

    var body: some View {
        VStack(spacing: 0) {
            if let coordinator {
                let action = VoiceControlInteractionPolicy.orbAction(
                    state: coordinator.state,
                    isHandsFreeArmed: coordinator.isHandsFreeArmed,
                    isHandsFreeCaptureActive: coordinator.isHandsFreeCaptureActive
                )
                let label = coordinator.state.isResponseActive
                    ? "Interrupt" : coordinator.state.isCaptureActive && !coordinator.isHandsFreeArmed
                    ? "Send early" : coordinator.isHandsFreeArmed ? statusLabel : "Start talking"
                Button {
                    inFlight = true
                    Task { @MainActor in
                        await VoiceControlInteractionPolicy.performPrimaryAction(on: coordinator)
                        inFlight = false
                    }
                } label: {
                    Label(label, systemImage: action.systemImage).frame(minHeight: 44)
                }
                .disabled(VoiceControlInteractionPolicy.isDisabled(
                    isActionInFlight: inFlight,
                    state: coordinator.state,
                    isHandsFreeArmed: coordinator.isHandsFreeArmed
                ))
                .accessibilityLabel(label)
                .accessibilityValue(statusLabel)
                .accessibilityHint(action.accessibilityHint)
                .accessibilityIdentifier("duo-transcript-voice-action")
                if coordinator.state.isCaptureActive && !coordinator.isHandsFreeArmed {
                    Button("Cancel") {
                        Task { await coordinator.cancelCapture() }
                    }
                    .frame(minHeight: 44)
                    .accessibilityHint("Discards the recording without sending.")
                }
                #if os(iOS)
                if coordinator.isHandsFreeArmed || coordinator.isHandsFreePending {
                    HandsFreePill(coordinator: coordinator)
                }
                #endif
            } else {
                Text(statusLabel).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
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
    var accessibilityFocus: AccessibilityFocusState<Bool>.Binding?
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
        .modifier(OrbAccessibilityFocus(binding: accessibilityFocus))
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

private struct OrbAccessibilityFocus: ViewModifier {
    let binding: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.accessibilityFocused(binding)
        } else {
            content
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
    var thinkingTurns: [ThinkingTurn] = []
    @State private var openThinkingID: UUID?
    @Environment(\.dismiss) private var dismiss
    private let exportFormatter = TranscriptExportFormatter()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ThinkingTranscriptOrdering.items(messages: messages, turns: thinkingTurns)) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message)
                        case .thinking(let turn):
                            ThinkingRow(turn: turn) { openThinkingID = turn.id }
                        }
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
            .sheet(item: Binding(
                get: { openThinkingID.flatMap { id in thinkingTurns.first { $0.id == id } } },
                set: { openThinkingID = $0?.id }
            )) { turn in
                ThinkingSheet(turn: turn)
            }
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
