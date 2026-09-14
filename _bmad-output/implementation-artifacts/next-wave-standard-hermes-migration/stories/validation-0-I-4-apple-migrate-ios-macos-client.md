---
story: 0-I-4
run_id: 20260914-170648-846a
status: blocked
phase: plan
---

# Story 0-I-4 validation record

## Outcome

The second unattended BMad pass read the now-published Home bridge contract
and generated an implementation plan, but its read-only plan gate returned
`fail`. No implementation, focused XCTest, iOS Simulator build/test, macOS
build/test, or live route check ran.

The upstream contract is no longer the blocker: it defines the planned
schema-1 `/api/v1/bridge/ws`, one endpoint-facing WebSocket, opaque handles,
Device authentication, route/session state, error codes, event/audio shapes,
no-replay reconnect, and the vanilla Hermes `0.21.1` ownership boundary. The
public Home adapter is still absent, so live route integration remains a
separate blocked evidence gate.

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

The local Story 4 spec and wrapper have been repaired against the Home
contract. Re-arm the auto loop for a fresh plan review. If that gate passes,
implementation may proceed only against the injectable fake Home bridge; keep
the public-adapter absence visible as a blocked live-integration condition.

## Evidence safety

This record contains no prompts, response text, credentials, raw protocol
frames, PCM bytes, microphone captures, or screenshots.
