import SwiftUI

struct VoiceOrbAction: Equatable, Sendable {
    let systemImage: String
    let prompt: String
    let accessibilityHint: String
}

enum VoiceControlInteractionPolicy {
    static func isResponseActive(_ state: VoiceState) -> Bool {
        state.isResponseActive
    }

    static func isVisible(
        isComposerFocused: Bool,
        state: VoiceState,
        isHandsFreeArmed: Bool = false
    ) -> Bool {
        !isComposerFocused || isResponseActive(state) || state.isCaptureActive || isHandsFreeArmed
    }

    /// Stopping capture can remain in flight while the response starts.
    /// Response states must stay tappable so that action can be interrupted.
    static func isDisabled(
        isActionInFlight: Bool,
        state: VoiceState,
        isHandsFreeArmed: Bool = false
    ) -> Bool {
        (isActionInFlight && !isResponseActive(state))
            || (isHandsFreeArmed && !isResponseActive(state))
    }

    /// What a tap on the voice orb will do, shown as its glyph and prompt.
    /// The orb shows the action; the status label beside it shows the state.
    static func orbAction(
        state: VoiceState,
        isHandsFreeArmed: Bool,
        isHandsFreeCaptureActive: Bool
    ) -> VoiceOrbAction {
        if isResponseActive(state) {
            return VoiceOrbAction(
                systemImage: "hand.raised.fill",
                prompt: "Tap to interrupt",
                accessibilityHint: isHandsFreeArmed
                    ? "Stops the reply."
                    : "Stops the reply and starts listening."
            )
        }
        if isHandsFreeArmed {
            return VoiceOrbAction(
                systemImage: isHandsFreeCaptureActive ? "waveform" : "ear",
                prompt: isHandsFreeCaptureActive ? "Hands-free listening" : "Listening for speech",
                accessibilityHint: "Hands-free is on. Turn it off to talk by tapping."
            )
        }
        if state.isCaptureActive {
            return VoiceOrbAction(
                systemImage: "stop.fill",
                prompt: "Tap to send",
                accessibilityHint: "Stops listening and sends what you said."
            )
        }
        return VoiceOrbAction(
            systemImage: "mic.fill",
            prompt: "Tap to talk",
            accessibilityHint: "Starts listening."
        )
    }

    /// The single voice action behind the voice orb: stop and send while
    /// capturing, interrupt a response, otherwise start capturing.
    @MainActor
    static func performPrimaryAction(on coordinator: VoiceSessionCoordinator) async {
        if coordinator.state.isCaptureActive {
            await coordinator.endCaptureAndSend()
        } else if isResponseActive(coordinator.state) {
            if coordinator.isHandsFreeArmed {
                _ = await coordinator.interruptActiveTurn()
            } else {
                await coordinator.interruptAndBeginCapture()
            }
        } else {
            await coordinator.beginCapture()
        }
    }
}

/// "Keep listening" (hands-free) as a quiet pill under the voice orb's status
/// line. Off is outlined; on is filled with the identity tint. iOS only.
struct HandsFreePill: View {
    let coordinator: VoiceSessionCoordinator
    @State private var isActionInFlight = false

    private var isOn: Bool { coordinator.isHandsFreeArmed }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .imageScale(.small)
                Text("Keep listening")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isOn ? HermesVisualTokens.onIdentity : HermesVisualTokens.secondaryInk)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule().fill(isOn ? HermesVisualTokens.identity : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(
                    isOn ? HermesVisualTokens.identity : HermesVisualTokens.secondaryInk.opacity(0.45),
                    lineWidth: 1
                )
            }
            // Keep a 44 pt hit area around the 30 pt capsule.
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            isActionInFlight
                || (coordinator.state.isCaptureActive && !coordinator.isHandsFreeCaptureActive)
        )
        .accessibilityLabel("Keep listening")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(Self.explanation)
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("keep-listening")
    }

    static let explanation = "Talk, pause, and Hermes answers. Tap the orb to interrupt."

    private func toggle() {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        Task { @MainActor in
            await coordinator.toggleHandsFree()
            isActionInFlight = false
        }
    }
}

/// Mutes Hermes's voice without interrupting the reply (IOS-UX-F8). It sits
/// beside the "Keep listening" pill, never shares Interrupt's glyph or label,
/// and shows the muted state with a slashed speaker and the word "Muted".
struct MuteButton: View {
    let coordinator: VoiceSessionCoordinator

    private var isMuted: Bool { coordinator.isMuted }

    var body: some View {
        Button(action: toggle) {
            Label(isMuted ? "Muted" : "Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .typingControlCapsule(
                    ink: isMuted ? HermesVisualTokens.attention : HermesVisualTokens.secondaryInk,
                    fill: .clear,
                    stroke: isMuted ? HermesVisualTokens.attention : HermesVisualTokens.secondaryInk.opacity(0.45),
                    lineWidth: isMuted ? 1.5 : 1
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute Hermes" : "Mute Hermes")
        .accessibilityHint("Silences Hermes's voice without stopping the reply.")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("mute-hermes")
    }

    private func toggle() {
        let muted = !coordinator.isMuted
        Task { @MainActor in
            await coordinator.setMuted(muted)
            // Announced once per change.
            AccessibilityNotification.Announcement(
                coordinator.isMuted ? "Hermes muted" : "Hermes unmuted"
            ).post()
        }
    }
}

/// What the typing view's control cluster offers in a voice state
/// (IOS-UX-F10). Talk, Mute and Interrupt are always shown, in the same
/// places, so nothing moves while a reply plays.
struct TypingControls: Equatable, Sendable {
    /// Whether Talk starts listening after returning to the voice view.
    /// It never interrupts: mid-reply it only switches views.
    let talkStartsListening: Bool
    let talkAccessibilityHint: String
    let isInterruptEnabled: Bool
}

enum TypingControlsPolicy {
    static func controls(state: VoiceState, isHandsFreeArmed: Bool) -> TypingControls {
        let isReplying = state.isResponseActive
        let hint: String
        let startsListening: Bool
        if isReplying {
            startsListening = false
            hint = "Returns to the voice view. The reply keeps playing."
        } else if state.isCaptureActive || isHandsFreeArmed {
            startsListening = false
            hint = "Returns to the voice view. Listening continues."
        } else {
            startsListening = true
            hint = "Returns to the voice view and starts listening."
        }
        return TypingControls(
            talkStartsListening: startsListening,
            talkAccessibilityHint: hint,
            isInterruptEnabled: isReplying
        )
    }
}

/// The typing view's controls, by the composer in the thumb zone
/// (IOS-UX-F10): Talk returns to the voice view, Mute silences Hermes
/// without ending the reply (IOS-UX-F8), Interrupt ends the reply. All three
/// stay available while a reply plays. Labels stay visible at every Dynamic
/// Type size; accessibility sizes stack the controls.
struct TypingControlCluster: View {
    let coordinator: VoiceSessionCoordinator
    /// Switches to the voice view and dismisses the keyboard.
    let onReturnToVoice: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            TalkButton(coordinator: coordinator, onReturnToVoice: onReturnToVoice)
            MuteButton(coordinator: coordinator)
            InterruptButton(coordinator: coordinator)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("typing-controls")
    }
}

/// Returns to the voice view (IOS-UX-F7 criterion 4). One tap, or ⌘⇧L on a
/// hardware keyboard, dismisses the keyboard and, when nothing is playing or
/// listening, starts listening through the coordinator's capture path, so
/// microphone permission is handled exactly as for the orb. During a reply
/// it never interrupts; the voice view's orb offers Interrupt. ⌘⇧L is
/// provisional until the large-format layout proposal (IOS-UX-F9) is approved.
struct TalkButton: View {
    let coordinator: VoiceSessionCoordinator
    let onReturnToVoice: () -> Void
    @State private var isActionInFlight = false

    private var controls: TypingControls {
        TypingControlsPolicy.controls(
            state: coordinator.state,
            isHandsFreeArmed: coordinator.isHandsFreeArmed
        )
    }

    var body: some View {
        Button(action: perform) {
            Label("Talk", systemImage: "mic.fill")
                .typingControlCapsule(
                    ink: HermesVisualTokens.onIdentity,
                    fill: HermesVisualTokens.identity,
                    stroke: HermesVisualTokens.identity
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .accessibilityLabel("Talk")
        .accessibilityValue(coordinator.state.label)
        .accessibilityHint(controls.talkAccessibilityHint)
        .accessibilityIdentifier("typing-talk")
    }

    private func perform() {
        let startsListening = controls.talkStartsListening
        // Leave the typing view first, so a denied microphone permission
        // lands on the voice view's existing permission state.
        onReturnToVoice()
        guard startsListening, !isActionInFlight else { return }
        isActionInFlight = true
        Task { @MainActor in
            await coordinator.beginCapture()
            isActionInFlight = false
        }
    }
}

/// Ends the reply from the typing view without starting to listen; the
/// typing view stays. Same glyph as the orb's interrupt action.
struct InterruptButton: View {
    let coordinator: VoiceSessionCoordinator

    private var isEnabled: Bool {
        TypingControlsPolicy.controls(
            state: coordinator.state,
            isHandsFreeArmed: coordinator.isHandsFreeArmed
        ).isInterruptEnabled
    }

    var body: some View {
        Button {
            Task { @MainActor in
                _ = await coordinator.interruptActiveTurn()
            }
        } label: {
            Label("Interrupt", systemImage: "hand.raised.fill")
                .typingControlCapsule(
                    ink: HermesVisualTokens.secondaryInk,
                    fill: .clear,
                    stroke: HermesVisualTokens.secondaryInk.opacity(0.45)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Interrupt")
        .accessibilityHint("Stops the reply.")
        .accessibilityIdentifier("typing-interrupt")
    }
}

extension View {
    /// The capsule shared by the voice-control pills: a 30 pt capsule that
    /// grows with Dynamic Type inside a hit area of at least 44 pt.
    func typingControlCapsule(ink: Color, fill: Color, stroke: Color, lineWidth: CGFloat = 1) -> some View {
        self
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background { Capsule().fill(fill) }
            .overlay { Capsule().strokeBorder(stroke, lineWidth: lineWidth) }
            .padding(.vertical, 7)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
