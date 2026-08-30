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
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isCapturing ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 64, height: 64)
                Image(systemName: coordinator.state.systemImage)
                    .font(.title2)
                    .foregroundStyle(isCapturing ? .white : .primary)
            }
            .contentShape(Circle())
            .gesture(pressAndHoldGesture)
            .accessibilityLabel("Voice control, \(coordinator.state.label.lowercased())")
            .accessibilityHint("Press and hold to speak. Release to send.")

            if isCapturing {
                Button("Cancel") {
                    Task { await coordinator.cancelCapture() }
                }
                .font(.footnote)
            }
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
