import SwiftUI

struct VoiceStatusView: View {
    let state: VoiceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .frame(width: 20)
            Text(state.label)
                .font(.footnote.weight(.medium))
            Spacer()
        }
        .foregroundStyle(stateColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice status, \(state.label)")
    }

    private var stateColor: Color {
        if case .failed = state { return .red }
        if state == .idle { return .secondary }
        return .accentColor
    }
}
