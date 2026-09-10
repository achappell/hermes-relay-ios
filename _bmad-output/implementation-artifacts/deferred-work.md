- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Preserve the recent transcript rail's live assistant identity through the playback-drain window.
  evidence: `ConversationStore` clears `activeAssistantID` when `turnComplete` is applied, so `RecentTranscriptProjection` cannot mark the assistant entry live while the coordinator is still draining output; this lifecycle predates Story 1.2 and needs a separate rail/store decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md`
  summary: Bound buffered audio-file memory before accepting arbitrarily large fallback payloads.
  evidence: `audioFileBuffer` still accumulates every `audio_file_chunk` until `audio_file_end`; this pre-existing transport/output boundary requires an explicit product limit and failure policy beyond the current slice.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define timeout and cancellation ownership for the production Device discovery adapter.
  evidence: DEVICE-01 handles Swift task cancellation without surfacing a false user failure, but no live adapter exists yet; the shared transport contract must define timeouts, cancellation propagation, and retry policy.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define the shared Device handshake and identity-proof requirements for connection receipts.
  evidence: DEVICE-01 accepts only an adapter receipt whose ID matches the requested candidate; cryptographic identity proof and attestation are intentionally deferred until Hermes and the physical Device share a settled contract.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Define the Device-side acknowledgement and observable success semantics for identity connection.
  evidence: The iOS model exposes explicit connecting/success states, while external acknowledgement must come from the future Device transport and cannot be fabricated by this client slice.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-discover-unconfigured-devices.md`
  summary: Run the interactive iOS Devices smoke plan with approved and unconfigured candidates.
  evidence: Deterministic model tests and an iOS hosting test cover the state boundary, and the simulator ran the automated suite; interactive visual verification remains pending because the shipped app still has no production fake-client injection path.

## Resolved on 2026-09-09

- Epic 1 iOS physical-device validation pass for Stories 1.1 and 1.2 completed. Evidence is recorded in `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md` and the IOS-36, IOS-29, and IOS-37 Project #3 cards. Deterministic tests remain authoritative for speaker/WAV fallback and late-event timing branches that were not observed live.

## Deferred from: code review of hermes-relay-ios-review-spec.XXXXXX.XV2EBX33l3 (2026-09-09)

- macOS permission failures expose a typed Settings action, but the shared macOS `ContentView` supplies no Settings URL; defer until macOS permission-recovery UX and URL handling are explicitly scoped.
