import SwiftUI

struct VoiceControl: View {
    let coordinator: VoiceSessionCoordinator

    private var isCapturing: Bool {
        switch coordinator.state {
        case .listening, .transcribing:
            return true
        default:
            return false
        }
    }

    private var isResponseActive: Bool {
        switch coordinator.state {
        case .thinking, .buffering, .speaking:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isCapturing
                        ? "Tap to stop"
                        : isResponseActive ? "Tap to interrupt" : "Tap to record"
                )
                    .font(.subheadline.weight(.semibold))
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
        }
    }

    struct RecordButton: View {
        let coordinator: VoiceSessionCoordinator
        @State private var isActionInFlight = false

        private var isCapturing: Bool {
            switch coordinator.state {
            case .listening, .transcribing:
                return true
            default:
                return false
            }
        }

        private var isResponseActive: Bool {
            switch coordinator.state {
            case .thinking, .buffering, .speaking:
                return true
            default:
                return false
            }
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
            .disabled(isActionInFlight)
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
            guard !isActionInFlight else { return }
            isActionInFlight = true
            let shouldEndCapture = isCapturing
            let shouldInterruptResponse = isResponseActive
            Task { @MainActor in
                if shouldEndCapture {
                    await coordinator.endCaptureAndSend()
                } else if shouldInterruptResponse {
                    await coordinator.interruptAndBeginCapture()
                } else {
                    await coordinator.beginCapture()
                }
                isActionInFlight = false
            }
        }
    }
}
