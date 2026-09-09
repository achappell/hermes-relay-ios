- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Preserve the recent transcript rail's live assistant identity through the playback-drain window.
  evidence: `ConversationStore` clears `activeAssistantID` when `turnComplete` is applied, so `RecentTranscriptProjection` cannot mark the assistant entry live while the coordinator is still draining output; this lifecycle predates Story 1.2 and needs a separate rail/store decision.

- source_specs:
    - `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
    - `IOS-36 Gate iOS turns on verified Hermes Profile sessions`
  summary: Run one signed physical-device validation pass for the current Epic 1 iOS slices (Stories 1.1 and 1.2), covering profile authorization, capture binding, honest phase delivery, audio/fallback behavior, permissions, interruption, recovery, and privacy review.
  plan: `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md`
  evidence: The available local SDK was Xcode 26.5, while the repository baseline requires Xcode 26.6 or newer; unsigned simulator validation cannot establish Keychain, microphone, speaker-route, or live-relay behavior. Track one evidence record for both IOS-36 and IOS-29, then extend this plan when Epic 1 Stories 1.3 and 1.4 ship on iOS.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Bound buffered audio-file memory before accepting arbitrarily large fallback payloads.
  evidence: `audioFileBuffer` still accumulates every `audio_file_chunk` until `audio_file_end`; this pre-existing transport/output boundary requires an explicit product limit and failure policy beyond the current slice.
