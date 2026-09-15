---
story: 0-I-4
run_id: 20260914-194500-story4-review-4
status: in-progress
phase: implementation
---

# Story 0-I-4 validation record

## Outcome

The first implementation slice is now written against the repaired plan. It
adds the typed Home bridge boundary, the production public-adapter gate, the
deterministic fake, secure credential/migration seams, opaque recovery state,
strict PCM joining, Apple lifecycle ownership, and the visible safe Home
status projection. The legacy Hermes client remains the explicit rollback
path. No live Home route was contacted.

The BMAD auto loop produced a preserved implementation snapshot before its
first development attempt timed out; the slice was recovered into the Story 4
worktree and verified manually at the code boundary. That timeout is recorded
as process history, not represented as a passing implementation gate.

The upstream contract is no longer the implementation blocker: it defines the planned
schema-1 `/api/v1/bridge/ws`, one endpoint-facing WebSocket, opaque handles,
Device authentication, route/session state, error codes, event/audio shapes,
no-replay reconnect, and the vanilla Hermes `0.21.1` ownership boundary. The
public Home adapter is still absent, so live route integration remains a
separate blocked evidence gate.

## Implementation evidence

The following local gates passed after the implementation recovery and the
Home audio/status repairs:

- Focused Home/lifecycle XCTest: 19 passed, 0 failed on macOS.
- Complete macOS XCTest: 343 passed, 0 failed.
- Complete iOS Simulator XCTest: 344 passed, 0 failed on iPhone 17 Pro,
  iOS 26.5.
- Generic iOS Simulator build: passed.
- Generic macOS build: passed.
- `git diff --check`: passed.
- Production factory gate: `public_adapter_unavailable` is returned before
  any Home socket operation when the public adapter is disabled.

The manual fake UI walkthrough could not be completed in this environment:
the installed simulator app was launchable with `-HomeBridgeFake`, but the
available computer-use surface could not attach to the iOS Simulator window.
No live route, microphone capture, screenshot, or private content was used.

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
Implementation is proceeding through the local BMad auto loop against the
injectable fake Home bridge; keep the public-adapter absence visible as a
blocked live-integration condition. The story remains `in-progress` because
the public adapter is not served and the full manual fake walkthrough still
requires a UI surface that can attach to the simulator.

## Evidence safety

This record contains no prompts, response text, credentials, raw protocol
frames, PCM bytes, microphone captures, or screenshots.
