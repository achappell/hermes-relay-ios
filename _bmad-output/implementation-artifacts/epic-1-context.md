# Epic 1 Context: Have a reliable Hermes conversation

<!-- Compiled from canonical Hermes Home planning sources. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

A configured Hermes doorway must complete an honest voice turn, make the observed lifecycle legible, deliver the same response through its supported text and audio surfaces, allow only a bounded follow-up where the surface supports it, and recover from transport loss without replaying an uncertain request. The repository-local planning-artifacts directory is not populated; this context is distilled from the canonical Hermes Home hub and its imported PRD, UX, and architecture sources.

## Stories

- Story 1.1: Start an authorized Hermes turn
- Story 1.2: Render honest turn phases and response delivery
- Story 1.3: Continue with bounded follow-up and exact `stop`
- Story 1.4: Recover without replaying an uncertain turn

## Requirements & Constraints

- A doorway fixes the selected Hermes Profile before capture or submission; missing authorization, unavailable identity, or an unverified handshake fails closed.
- Supported surfaces expose only phases justified by observed events: `heard`, `listening`, `transcribing`, `thinking`, `buffering`, `speaking`, `complete`, or an honest Disconnected State. A local user stop may be presented as `Stopped` but is not a Hermes response phase.
- Text-capable surfaces render one coherent response from the active turn. Voice-capable surfaces play that same Hermes response; local clients must not invent, paraphrase, or replace answer content.
- A response whose text is complete but whose audio cannot start preserves the completed text and reports audio as unavailable. A display-only surface never implies that it is playing audio.
- Unknown, stale, or differently identified events must not mutate the active turn or response; any diagnostics are opt-in and content-safe.
- Transport loss is visible and recoverable, but an active turn that may have reached Hermes is never automatically replayed. Recovery creates a fresh verified Session and requires explicit new initiation.
- No microphone upload, remote undo, usage, compression, or server-side interruption operation may be invented before Hermes exposes that contract.

## Technical Decisions

- Use ports and adapters with one owner per state domain. The client/session boundary owns Hermes protocol normalization and session facts; the front end owns presentation and local capture/playback state.
- Keep raw JSON and WebSocket frames inside the transport adapter. Views and stores consume typed normalized events through `HermesSessionClient`.
- Maintain one WebSocket reader. Gate connected state on the protocol-v1 `hello_ack`; correlate turn events and audio to the verified session/turn identity.
- Keep platform capabilities behind injectable `Sendable` protocols and deterministic fakes. Blocking capture and playback stay off the UI event loop/main actor.
- Preserve independent doorway deployment and local history boundaries. iOS is a Client doorway; physical Device administration and room mirroring are separate concerns.

## UX & Interaction Patterns

- The iOS Client presents one calm conversation hierarchy with the active Profile visible before capture, a clear current state, typed/tap-to-speak interaction, streamed transcript, and deliberate Local History.
- State wording is short and child-readable. Permission, relay, network, and playback failures identify the failed path and the next action; none masquerades as another phase.
- A cancelled local capture returns to ready without submitting, losing the existing draft, or leaving a capture task running. A failed speaker leaves response text visible.
- The canonical journey is identity fixed → heard/listening → transcribing → thinking → buffering/speaking → complete. Surfaces may omit unobservable phases but never show a later phase early.

## Cross-Story Dependencies

Story 1.1 establishes authorization, verified session ownership, and exactly-once initial submission. Story 1.2 consumes those normalized events and provides the canonical phase/response projection. Story 1.3 depends on the completed-turn boundary and applies only to a Puck-like bounded follow-up surface. Story 1.4 depends on session identity and stale-event isolation from the earlier stories. Later display, device-administration, and portable-client work consumes these semantics but must not create a second protocol or state authority.
