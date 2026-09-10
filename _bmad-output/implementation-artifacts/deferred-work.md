- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Preserve the recent transcript rail's live assistant identity through the playback-drain window.
  evidence: `ConversationStore` clears `activeAssistantID` when `turnComplete` is applied, so `RecentTranscriptProjection` cannot mark the assistant entry live while the coordinator is still draining output; this lifecycle predates Story 1.2 and needs a separate rail/store decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Bound buffered audio-file memory before accepting arbitrarily large fallback payloads.
  evidence: `audioFileBuffer` still accumulates every `audio_file_chunk` until `audio_file_end`; this pre-existing transport/output boundary requires an explicit product limit and failure policy beyond the current slice.

## Resolved on 2026-09-09

- Epic 1 iOS physical-device validation pass for Stories 1.1 and 1.2 completed. Evidence is recorded in `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md` and the IOS-36, IOS-29, and IOS-37 Project #3 cards. Deterministic tests remain authoritative for speaker/WAV fallback and late-event timing branches that were not observed live.

## Deferred from: code review of hermes-relay-ios-review-spec.XXXXXX.XV2EBX33l3 (2026-09-09)

- macOS permission failures expose a typed Settings action, but the shared macOS `ContentView` supplies no Settings URL; defer until macOS permission-recovery UX and URL handling are explicitly scoped.
