---
story: 0-I-4
run_id: 20260915-172301-story4-review-5
status: review
phase: review
---

# Story 0-I-4 validation record

## Outcome

The Apple implementation is written against the repaired plan. It adds the
typed Home bridge boundary, the production public-adapter gate, the
deterministic fake, secure credential/migration seams, opaque recovery state,
strict PCM joining, Apple lifecycle ownership, and the visible safe Home
status projection. The legacy Hermes client remains the explicit rollback
path.

The deployed listener for the planned `/api/v1/bridge/ws` transport accepted a
WebSocket request with a deliberately synthetic `Authorization: Device`
credential. A schema-1 `conversation.open` probe returned
`status: unavailable` with `reason: hermes_unavailable`. No real Device
credential, prompt, turn, or audio was sent. This proves only that a listener
responded; it does not prove that the public Home adapter is available. The
live gate is therefore `public_adapter_unavailable`.

The BMAD auto loop preserved the existing Story 4 implementation and used a
focused audit pass to close the remaining contract gaps. The strict typed
payload checks were verified with a deterministic RED run (two failures) and a
GREEN run (two passes) before the broader suites.

The upstream contract is no longer the implementation blocker: it defines the
planned schema-1 `/api/v1/bridge/ws`, one endpoint-facing WebSocket, opaque
handles, Device authentication, route/session state, error codes, event/audio
shapes, no-replay reconnect, and the vanilla Hermes `0.21.1` ownership
boundary. The public Home adapter is still unavailable, so live route
integration remains a separate blocked evidence gate.

## Implementation evidence

The following local gates passed after the contract audit:

- `xcodebuild -list`: project `Hermes Relay.xcodeproj`, scheme `HermesRelay`,
  test target `Hermes RelayTests`.
- Focused deterministic coverage across the requested Home, lifecycle,
  persistence, recovery, transport, voice, audio, and configuration seams: 211
  passed, 0 failed on macOS.
- Complete macOS XCTest: 349 passed, 0 failed.
- Complete iOS Simulator XCTest: 350 passed, 0 failed on the discovered
  iPhone 17 Pro simulator, iOS 26.5.
- Generic iOS Simulator build: passed.
- Generic macOS build: passed.
- `git diff --check`: passed.
- Production factory gate: `public_adapter_unavailable` is returned before
  any Home socket operation when the public adapter is disabled.

The manual fake UI walkthrough could not be completed in this environment. The
discovered simulator accepted installation and a `-HomeBridgeFake` launch
request, but the available computer-use surface could not attach to the iOS
Simulator window. No manual scenario is marked passed. No microphone capture,
screenshot, or private content was used.

## Review evidence

Run `20260914-170648-846a` returned 13 actionable findings. The plan needed to:

- resolve sibling companion paths;
- model one Apple Home socket with one reader and logical audio/control
  demultiplexing, keeping Standard's gateway/audio sockets Home-owned;
- define opaque binding types instead of reusing or leaking Standard
  `sessionID`;
- define typed Home route/bridge/turn states, stable errors, operation
  deadlines, and known-rejected versus uncertain delivery;
- make pre-issued Device-credential conversion, persisted phases, crash-safe
  verification, idle-boundary rollback, and legacy retention explicit;
- assign structured prompt/command actions and secret redaction;
- specify the control/audio join, strict PCM metadata, audio failure, timing
  absence, interrupt confirmation, route-loss phases, and Apple lifecycle;
- provide a reproducible Debug fake injection path and pin fake provenance to
  Standard commit `2237be355906fbe6065ce1815711eee52b2d646e`.

## Resume condition

The local Story 4 spec and wrapper are repaired against the Home contract.
Implementation and deterministic Apple gates are ready for review through the
injectable fake Home bridge. The story remains `review`, not `done`, because
the public adapter is unavailable and the full manual fake walkthrough still
requires a UI surface that can attach to the simulator.

## Evidence safety

This record contains no prompts, response text, credentials, raw protocol
frames, PCM bytes, microphone captures, or screenshots.
