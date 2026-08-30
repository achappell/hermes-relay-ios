import SwiftUI

@MainActor
struct ContentView: View {
    @State private var store: ConversationStore
    @State private var voiceCoordinator: VoiceSessionCoordinator

    init(
        store: ConversationStore = ConversationStore(),
        voiceCoordinator: VoiceSessionCoordinator? = nil
    ) {
        _store = State(initialValue: store)
        _voiceCoordinator = State(
            initialValue: voiceCoordinator ?? VoiceSessionCoordinator(
                store: store,
                input: AppleSpeechInput(),
                output: RecoveringAudioOutput(liveOutput: AppleAudioOutput())
            )
        )
    }

    private var canSend: Bool {
        store.connectionState.isConnected
            && !store.isSending
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectionBanner
                transcript
                voiceInterface
                composer
            }
            .navigationTitle("Hermes Relay")
            .task {
                await store.loadConfiguredClient()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    connectButton
                }
                #else
                ToolbarItem {
                    connectButton
                }
                #endif
            }
        }
    }

    private var connectButton: some View {
        Button(store.connectionState.isConnected ? "Connected" : "Connect") {
            Task { await store.connect() }
        }
        .disabled(store.connectionState == .connecting)
    }

    private var connectionBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.connectionState.isConnected ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(store.connectionState.label)
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.messages.isEmpty {
                    ContentUnavailableView(
                        "Conversation shell ready",
                        systemImage: "waveform.and.person.filled",
                        description: Text("Connect a configured Hermes relay to stream a text turn.")
                    )
                    .padding(.top, 72)
                } else {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let activityText = store.activityText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityText)
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            if let transientError = store.transientError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(transientError)
                        .font(.footnote)
                    Spacer()
                    Button {
                        store.clearTransientError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss message")
                }
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await store.sendDraft() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding()
        .background(.bar)
    }

    private var voiceInterface: some View {
        VStack(spacing: 8) {
            VoiceStatusView(state: voiceCoordinator.state)
            if !voiceCoordinator.provisionalText.isEmpty {
                Text(voiceCoordinator.provisionalText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            VoiceControl(coordinator: voiceCoordinator)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

#Preview {
    ContentView()
}
