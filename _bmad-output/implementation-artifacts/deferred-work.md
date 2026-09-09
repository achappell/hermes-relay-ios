- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Preserve the recent transcript rail's live assistant identity through the playback-drain window.
  evidence: `ConversationStore` clears `activeAssistantID` when `turnComplete` is applied, so `RecentTranscriptProjection` cannot mark the assistant entry live while the coordinator is still draining output; this lifecycle predates Story 1.2 and needs a separate rail/store decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Repeat the signed credentialed device walkthrough on the repository's supported Xcode 26.6-or-newer toolchain.
  evidence: The available local SDK was Xcode 26.5, while the repository baseline requires Xcode 26.6 or newer; simulator validation used signing disabled and therefore cannot establish Keychain, microphone, or live-relay behavior.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Bound buffered audio-file memory before accepting arbitrarily large fallback payloads.
  evidence: `audioFileBuffer` still accumulates every `audio_file_chunk` until `audio_file_end`; this pre-existing transport/output boundary requires an explicit product limit and failure policy beyond the current slice.
