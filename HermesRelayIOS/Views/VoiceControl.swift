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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCapturing ? "Tap to stop" : "Tap to record")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer(minLength: 8)

            Button("Cancel") {
                Task { await coordinator.cancelCapture() }
            }
            .font(.footnote.weight(.medium))
            .opacity(isCapturing ? 1 : 0)
            .allowsHitTesting(isCapturing)
            .accessibilityHidden(!isCapturing)
            .relayGlassButtonStyle()

            RecordButton(coordinator: coordinator)
            .frame(width: 52, height: 52)
            .relayCircleGlass(tint: isCapturing ? .accentColor : nil, interactive: false)
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

        var body: some View {
            Button(action: toggleCapture) {
                Image(systemName: coordinator.state.systemImage)
                    .font(.headline)
                    .foregroundStyle(isCapturing ? .white : .primary)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .background {
                        if isCapturing {
                            Circle().fill(Color.pink)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isActionInFlight)
            .accessibilityLabel("Voice control")
            .accessibilityValue(isCapturing ? "Recording. Tap to stop." : "Ready. Tap to record.")
            .accessibilityHint(isCapturing ? "Tap to stop recording and send." : "Tap to start recording.")
        }

        private func toggleCapture() {
            guard !isActionInFlight else { return }
            isActionInFlight = true
            let shouldEndCapture = isCapturing
            Task { @MainActor in
                if shouldEndCapture {
                    await coordinator.endCaptureAndSend()
                } else {
                    await coordinator.beginCapture()
                }
                isActionInFlight = false
            }
        }
    }
}
