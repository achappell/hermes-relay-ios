# Epic 2 Context: See and trust what the room is doing

<!-- Compiled from canonical Hermes Home planning sources. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

The iOS Client's slice of this epic is narrow: while a voice turn is active on any authorized doorway (Puck, ESP32 Touch, W/K browser), the iOS app shows its own honest capture acknowledgement and live partial Transcription as that turn's events arrive, and shows an honest disconnected/unavailable state without replaying a stale turn when connectivity is lost. iOS is a participant surface here, not the passive Room Display itself — the Room-scoped Ambient Surface, Active-Turn mirroring, and Hermes-prompt mirroring stories in this epic belong to the ESP32 Touch Display and W/K browser surfaces, not iOS. The repository-local planning-artifacts directory is not populated; this context is distilled from the canonical Hermes Home hub and the shared surface-specific epics source in `hermes-relay-tui`.

## Stories

- Story 2.1: Show the iOS doorway's capture acknowledgement and live Transcription participant state
- Story 2.2: Show honest iOS disconnected/unavailable state without stale-turn replay

## Requirements & Constraints

- When an authorized wake or explicit turn initiation is accepted on any voice doorway, iOS shows its own capture acknowledgement and Listening state as a participant, without claiming to own capture it did not perform.
- When partial transcription becomes available for the active turn, iOS updates live as words arrive rather than waiting for capture to finish.
- When capture ends or is cancelled, iOS's Listening indicator clears and advances to the appropriate next phase; it never leaves a stale Listening indicator.
- iOS never submits an empty Hermes turn and never retains raw audio or transcription beyond what the active turn/session already governs.
- When the Media Server, Hermes connection, or transport becomes unavailable, iOS shows a persistent, visible Disconnected/Unavailable state rather than remaining indefinitely in a Thinking or Listening phase.
- iOS may continue showing safe cached context (e.g. the last completed response) during a Disconnected State, with a clear stale/cached indication; it never implies a live answer it does not have.
- When Hermes/transport recovers, iOS clears the Disconnected State without silently reopening capture or resuming an unresolved prior turn — recovery requires a fresh verified Session and explicit new initiation (see Epic 1's recovery contract, which this story reuses rather than redefines).
- A stale event, or an event for another Room, Session, or turn, must not mutate iOS's current transcription or capture-state display.

## Technical Decisions

- Reuse Epic 1's client/session boundary: `HermesSessionClient` owns Hermes protocol normalization and session/turn identity; the front end owns presentation of capture and connection state. Do not introduce a second transport or event-normalization path for this epic.
- Correlate every capture-state and transcription update to the verified session/turn identity from the single WebSocket reader; discard anything that doesn't match the active session/turn rather than merging it.
- Disconnected/Unavailable presentation must be visually distinct from `Stopped` (local user stop) and from the honest Hermes turn phases (`heard`, `listening`, `transcribing`, `thinking`, `buffering`, `speaking`, `complete`) defined in Epic 1 — do not overload an existing phase to mean "disconnected."
- No microphone upload, remote undo, usage, compression, or server-side interruption operation may be invented before Hermes exposes that contract (same boundary as Epic 1 and `AGENTS.md`).

## UX & Interaction Patterns

- Capture acknowledgement and live partial Transcription render as iOS's own participant state, not as a mirror of another surface's display — iOS is not a passive Room Display and must not adopt that role's Ambient Surface, Active-Turn-mirroring, or prompt-mirroring behavior (those are ESP32 Touch/W/K stories, out of scope here).
- Disconnected/Unavailable state is persistent and visible, not a transient toast; any retry is an explicit user action, never automatic or silent.

## Cross-Story Dependencies

- Depends on Epic 1's turn-phase, session, and recovery contracts (Stories 1.2 and 1.4 in this repository's local numbering); this epic must not redefine phase semantics or the fresh-recovery rule, only apply them to capture-acknowledgement and disconnected-state presentation.
- Shares its normalized turn-event and session/turn-identity model with the ESP32 Touch Display, W/K browser, and TUI surfaces in `hermes-relay-tui`, but each surface's implementation and closure are independent per `AGENTS.md`.
