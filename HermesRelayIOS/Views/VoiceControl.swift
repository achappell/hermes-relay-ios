import SwiftUI

struct VoiceControl: View {
    let coordinator: VoiceSessionCoordinator
    @State private var isPressed = false

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
                Text(isCapturing ? "Release to send" : "Hold to speak")
                    .font(.subheadline.weight(.semibold))
                Text(coordinator.state.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isCapturing {
                Button("Cancel") {
                    Task { await coordinator.cancelCapture() }
                }
                .font(.footnote.weight(.medium))
                .relayGlassButtonStyle()
            }

            ZStack {
                Image(systemName: coordinator.state.systemImage)
                    .font(.headline)
                    .foregroundStyle(isCapturing ? .white : .primary)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .gesture(pressAndHoldGesture)
            .accessibilityLabel("Voice control, \(coordinator.state.label.lowercased())")
            .accessibilityHint("Press and hold to speak. Release to send.")
            .relayCircleGlass(tint: isCapturing ? .accentColor : nil, interactive: true)
        }
    }

    private var pressAndHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                Task { await coordinator.beginCapture() }
            }
            .onEnded { _ in
                isPressed = false
                Task { await coordinator.endCaptureAndSend() }
            }
    }
}
