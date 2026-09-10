import SwiftUI

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
}

struct VoiceControl: View {
    let coordinator: VoiceSessionCoordinator

    private var isCapturing: Bool {
        coordinator.state.isCaptureActive
    }

    private var isResponseActive: Bool {
        VoiceControlInteractionPolicy.isResponseActive(coordinator.state)
    }

    private var isHandsFreeCaptureActive: Bool {
        coordinator.isHandsFreeCaptureActive
    }

    private var isHandsFreeWaiting: Bool {
        coordinator.isHandsFreeArmed && !isHandsFreeCaptureActive && !isResponseActive
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isHandsFreeCaptureActive
                        ? "Hands-free listening"
                        : isHandsFreeWaiting
                        ? "Listening for speech"
                        : isCapturing
                        ? "Tap to stop"
                        : isResponseActive ? "Tap to interrupt" : "Tap to record"
                )
                    .font(.subheadline.weight(.semibold))

                #if os(iOS)
                Text(coordinator.handsFreeStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Spacer(minLength: 8)

            if isCapturing {
                Button("Cancel") {
                    Task { await coordinator.cancelCapture() }
                }
                .font(.footnote.weight(.medium))
                .relayGlassButtonStyle()
            }

            RecordButton(coordinator: coordinator)
            .frame(width: 52, height: 52)
            .relayCircleGlass(
                tint: isCapturing ? .accentColor : isResponseActive ? .orange : nil,
                interactive: false
            )

            #if os(iOS)
            HandsFreeButton(coordinator: coordinator)
                .frame(width: 44, height: 44)
                .relayCircleGlass(
                    tint: coordinator.isHandsFreeArmed ? .accentColor : nil,
                    interactive: false
                )
            #endif
        }
    }

    struct RecordButton: View {
        let coordinator: VoiceSessionCoordinator
        @State private var isActionInFlight = false

        private var isCapturing: Bool {
            coordinator.state.isCaptureActive
        }

        private var isResponseActive: Bool {
            VoiceControlInteractionPolicy.isResponseActive(coordinator.state)
        }

        var body: some View {
            Button(action: toggleCapture) {
                Image(systemName: coordinator.state.systemImage)
                    .font(.headline)
                    .foregroundStyle(isCapturing || isResponseActive ? .white : .primary)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .background {
                        if isCapturing {
                            Circle().fill(Color.pink)
                        } else if isResponseActive {
                            Circle().fill(Color.orange)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(
                VoiceControlInteractionPolicy.isDisabled(
                    isActionInFlight: isActionInFlight,
                    state: coordinator.state,
                    isHandsFreeArmed: coordinator.isHandsFreeArmed
                )
            )
            .accessibilityLabel("Voice control")
            .accessibilityValue(
                isCapturing
                    ? "Recording. Tap to stop."
                    : isResponseActive
                        ? "Response playing. Tap to interrupt."
                        : "Ready. Tap to record."
            )
            .accessibilityHint(
                isCapturing
                    ? "Tap to stop recording and send."
                    : isResponseActive
                        ? "Tap to stop playback and start a new recording."
                        : "Tap to start recording."
            )
        }

        private func toggleCapture() {
            guard !isActionInFlight || isResponseActive else { return }
            isActionInFlight = true
            let shouldEndCapture = isCapturing
            let shouldInterruptResponse = isResponseActive
            Task { @MainActor in
                if shouldEndCapture {
                    await coordinator.endCaptureAndSend()
                } else if shouldInterruptResponse {
                    if coordinator.isHandsFreeArmed {
                        _ = await coordinator.interruptActiveTurn()
                    } else {
                        await coordinator.interruptAndBeginCapture()
                    }
                } else {
                    await coordinator.beginCapture()
                }
                isActionInFlight = false
            }
        }
    }

    struct HandsFreeButton: View {
        let coordinator: VoiceSessionCoordinator
        @State private var isActionInFlight = false

        var body: some View {
            Button(action: toggleHandsFree) {
                Image(systemName: coordinator.handsFreeStatus.systemImage)
                    .font(.headline)
                    .foregroundStyle(coordinator.isHandsFreeArmed ? .white : .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background {
                        if coordinator.isHandsFreeArmed {
                            Circle().fill(Color.accentColor)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(
                isActionInFlight
                    || (coordinator.state.isCaptureActive && !coordinator.isHandsFreeCaptureActive)
            )
            .accessibilityLabel("Hands-free mode")
            .accessibilityValue(
                coordinator.isHandsFreeArmed
                    ? coordinator.handsFreeStatus.label
                    : "Off"
            )
            .accessibilityHint(
                coordinator.isHandsFreeArmed
                    ? "Tap to stop hands-free listening."
                    : "Tap to enable hands-free listening."
            )
        }

        private func toggleHandsFree() {
            guard !isActionInFlight else { return }
            isActionInFlight = true
            Task { @MainActor in
                await coordinator.toggleHandsFree()
                isActionInFlight = false
            }
        }
    }
}
