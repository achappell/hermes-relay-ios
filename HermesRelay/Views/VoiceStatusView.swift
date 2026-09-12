import SwiftUI

struct VoiceStatusView: View {
    let state: VoiceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .frame(width: 20)
            Text(state.label)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(stateColor)
        .relayPanel(cornerRadius: 16, fill: HermesVisualTokens.panel)
        .animation(.easeInOut(duration: 0.2), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice status, \(state.label)")
        .accessibilityIdentifier("voice-status-indicator")
    }

    private var stateColor: Color {
        if case .failed = state { return HermesVisualTokens.unavailable }
        if state == .complete { return HermesVisualTokens.live }
        if state == .idle { return HermesVisualTokens.secondaryInk }
        return HermesVisualTokens.identity
    }
}
