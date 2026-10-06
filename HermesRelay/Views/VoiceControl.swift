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
