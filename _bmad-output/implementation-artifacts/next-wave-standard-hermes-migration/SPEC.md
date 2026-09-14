---
id: SPEC-ios-next-wave-standard-hermes-migration
companions:
  - ../../../hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/SPEC.md
  - ../../../hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/standard-baseline.md
  - ../../../hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/surface-migration-matrix.md
  - ../../../hermes-relay-home/_bmad-output/specs/spec-standard-hermes-compatibility-migration/compatibility-and-rollout.md
  - ../../../hermes-relay-home/_bmad-output/planning-artifacts/architecture/architecture-hermes-relay-home-2026-09-12/ARCHITECTURE-SPINE.md
  - ../../../docs/bmad-upstream.md
---

# iOS/macOS Standard Hermes Migration

This is the iOS-owned delivery wrapper for Story 4 of the canonical Standard
Hermes compatibility migration. The sibling Home artifacts listed above own
the shared contract, pinned release, capability matrix, and rollout gates;
this folder owns only the Apple client adapter, local configuration conversion,
Apple lifecycle behavior, and evidence for this surface.

The existing `SessionProtocol`/normalized-event seam remains the presentation
boundary. SwiftUI, local Profile and conversation history, Keychain-backed
credentials, microphone permission, playback, interruption, reconnect, and
macOS/iOS lifecycle concerns remain in this repository. The Standard path must
not gain a second Hermes parser, infer timing from network arrival, expose a
personal bearer token to an endpoint, switch routes during an active or
uncertain turn, or replay an uncertain turn.
