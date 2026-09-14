---
id: SPEC-ios-next-wave-standard-hermes-migration
companions:
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-home-bridge-route-roaming/bridge-contract.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-home-bridge-route-roaming/SPEC.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-home-bridge-route-roaming/route-session-state.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/standard-baseline.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/surface-migration-matrix.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-home-service-foundation/credential-lifecycle.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-standard-bridge/transport-contract.md
  - ~/Development/hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/compatibility-and-rollout.md
  - ~/Development/hermes-relay-home/_bmad-output/planning-artifacts/architecture/architecture-hermes-relay-home-2026-09-12/ARCHITECTURE-SPINE.md
  - ../../../docs/bmad-upstream.md
---

# iOS/macOS Standard Hermes Migration

This is the iOS-owned delivery wrapper for Story 4 of the canonical Standard
Hermes compatibility migration. The sibling Home artifacts listed above own
the Home authentication, approved-route selection and Household Identity
boundary, opaque conversation handles, reconnect semantics, redaction, and
the planned `/api/v1/bridge/ws` envelope. Vanilla Hermes `0.21.1` owns only
the backend `/api/ws` JSON-RPC gateway and separate
`/api/audio/speak-stream` sidecar that Home opens with its server-held token.

The public Home adapter is not live in the current Home revision. This folder
owns only the Apple client adapter behind the existing normalized session seam,
local Device-credential storage/conversion, Apple lifecycle behavior, fake
Home-bridge evidence, and a clearly blocked live-route gate. The client must
not send Home methods directly to vanilla `/api/ws`, claim live route
integration, or fall back to personal Hermes bearer access.

The existing `SessionProtocol`/normalized-event seam remains the presentation
boundary. SwiftUI, local Profile and conversation history, Keychain-backed
Device credentials, microphone permission, playback, interruption, reconnect,
and macOS/iOS lifecycle concerns remain in this repository. The Apple adapter
consumes Home `schema: 1` JSON-RPC `conversation.open`,
`conversation.reconnect`, `prompt.submit`, `session.interrupt`, structured
prompt, command, `event`, and `audio.frame` shapes through an injectable fake
until the public endpoint exists. It preserves Standard event meaning,
cumulative previews, sidecar PCM metadata and boundaries, typed timing
absence, and no-replay recovery. It must not add a second Hermes parser,
infer timing from network arrival, expose a personal or server-held bearer
token, switch routes during an active or uncertain turn, or replay an uncertain
turn.
