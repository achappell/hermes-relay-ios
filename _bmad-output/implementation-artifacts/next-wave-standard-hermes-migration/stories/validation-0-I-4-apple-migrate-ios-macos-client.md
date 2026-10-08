---
story: 0-I-4
run_id: 20260915-222240-story4-review-7
status: done
phase: done
---

# Story 0-I-4 validation record

## Outcome

The Apple implementation is written against the repaired plan. It adds the
typed Home bridge boundary, the production public-adapter gate, the
deterministic fake, secure credential/migration seams, opaque recovery state,
strict PCM joining, Apple lifecycle ownership, and the visible safe Home
status projection. The legacy Hermes client remains the explicit rollback
path.

Historical probe (superseded by the 2026-09-21 live Home follow-up below): the
deployed listener for the planned `/api/v1/bridge/ws` transport accepted a
WebSocket request with a deliberately synthetic `Authorization: Device`
credential. A schema-1 `conversation.open` probe returned
`status: unavailable` with `reason: hermes_unavailable`. No real Device
credential, prompt, turn, or audio was sent. This proves only that a listener
responded; it does not prove that the public Home adapter is available. The
live gate is therefore `public_adapter_unavailable`.

The BMAD auto loop preserved the existing Story 4 implementation and used a
focused audit pass to close the remaining contract gaps. The parent re-review
added deterministic fake-based coverage first. That pass caught a shared Home
turn-waiter race and a stale uncertainty marker during the matching-terminal
test; the smallest production fixes now settle both callers and clear only a
fully settled turn.

The upstream contract is no longer the implementation blocker: it defines the
planned schema-1 `/api/v1/bridge/ws`, one endpoint-facing WebSocket, opaque
handles, Device authentication, route/session state, error codes, event/audio
shapes, no-replay reconnect, and the vanilla Hermes `0.21.1` ownership
boundary. At the time of this implementation pass the public Home adapter was
still unavailable, so live route integration was a separate blocked evidence
gate. That gate was later cleared by the 2026-09-21 live Home follow-up below.

## Implementation evidence

The following local gates passed after the contract audit:

- `xcodebuild -list`: project `Hermes Relay.xcodeproj`, scheme `HermesRelay`,
  test target `Hermes RelayTests`.
- Focused deterministic coverage across the requested Home, lifecycle,
  persistence, recovery, transport, voice, audio, and configuration seams: 237
  passed, 0 failed on arm64 macOS 27.0.
- Complete macOS XCTest: 375 passed, 0 failed on arm64 macOS 27.0.
- Complete iOS Simulator XCTest: 376 passed, 0 failed on the runtime-resolved
  iPhone 17 Pro simulator, iOS 26.5.
- Generic iOS Simulator build: passed.
- Generic macOS build: passed.
- `git diff --check`: passed.
- Production factory gate: `public_adapter_unavailable` is returned before
  any Home socket operation when the public adapter is disabled.

The eleven delegated BMAD review patches and seven parent-review findings are
checked off in the owning story. The Home bridge tests pass with strict
Boolean/integer validation, typed JSON-RPC fallback errors, fractional expiry
parsing, conversation mismatch preservation, unknown-event handling, exact
malformed envelope errors, typed audio-invalid settlement, reconnect audio
reset, known rejection retry, typed prompt resolution, and Store/Recovery/
Voice interruption and text-preservation coverage.

The manual fake UI walkthrough could not be completed in this environment
(superseded on owner decision; see Acceptance — 2026-10-07). The
discovered simulator accepted installation and a `-HomeBridgeFake` launch
request, but the available computer-use surface could not attach to the iOS
Simulator window. No manual scenario is marked passed. No microphone capture,
screenshot, or private content was used.

## Parent review evidence

The bounded delegated re-review layers returned no findings, so the parent
review traced the complete diff against the Home bridge contract and its Store
callers. All seven parent findings were patched with deterministic TDD. The
matching-terminal regression then exposed and closed the two caller-level
defects recorded above. Final focused, iOS Simulator, macOS, build, and diff
gates passed after those fixes.

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

Resolved. At the implementation pass the story stayed `review`, not `done`,
because the public adapter was unavailable and the full manual fake walkthrough
required a UI surface that could attach to the simulator. The public adapter
has since been served and verified live (2026-09-21 live Home follow-up), and
Amanda accepted the story as `done` on 2026-10-07 on live evidence in place of
the fake walkthrough; see Acceptance — 2026-10-07.

## Evidence safety

This record contains no prompts, response text, credentials, raw protocol
frames, PCM bytes, microphone captures, or screenshots.

## 2026-09-21 closeout verification

The current merged implementation was re-run on the runtime-resolved iPhone 17 Pro simulator. Focused Home/relay/voice coverage executed 133 tests with 0 failures. The complete iOS Simulator suite executed 446 tests with 0 failures. The arm64 macOS build completed successfully, and the repository diff check passed.

The Home route was rechecked after the tailnet repair. At this checkpoint, Tailscale reached the approved Home host, but the WSS route returned HTTP 502 and the Hermes Relay client remained `Home bridge Unavailable`. No Device credential, prompt, turn, audio, or private content was sent. The route was therefore not live evidence for STD-4 at that checkpoint, and the story remained `review` rather than `done`.

This closes the iOS implementation and deterministic validation lane. The subsequent live Home follow-up below records the deployment and operator-authorization verification; the manual fake-bridge matrix was not completed and was later superseded on owner decision; see Acceptance — 2026-10-07.

## 2026-09-21 live Home follow-up

After the managed Home bridge task was restarted, the approved route returned HTTP 401 to an unauthenticated probe, confirming the authentication boundary. The Relay then completed a live `conversation.open` handshake using secure in-app Device-credential provisioning for the Kitchen/Hey Missy claim and reported `Home bridge Ready` and `Approved route reachable`. Amanda confirmed that voice control also works. This follow-up contains no credential, prompt, response text, raw protocol frame, PCM data, microphone capture, or private content.

## Acceptance — 2026-10-07

Amanda accepted 0-I-4 (alias STD-4, `standard-4-apple-migrate-client`) as
`done` on 2026-10-07.

- **Accepted evidence:** the 2026-09-21 live Home follow-up above (live
  `conversation.open`, `Home bridge Ready`, `Approved route reachable`, voice
  control confirmed by Amanda). On owner decision, this evidence supersedes the
  uncompleted `-HomeBridgeFake` walkthrough for this migration story only.
- **No new test run:** this acceptance is a documentation and status change. It
  did not run builds, tests, device checks, or Home traffic.
- **Scope:** this closes only 0-I-4/STD-4. IOS-HOME-07's device and slow-turn
  gates remain unchanged and unwaived; this acceptance does not close or waive
  any IOS-HOME-07 criterion.
- **Historical text:** the `public_adapter_unavailable` outcome, the "stays
  `review`" resume condition, and the 2026-09-21 closeout sentence that the
  manual fake matrix was the review boundary describe earlier checkpoints.
  `public_adapter_unavailable` remains the Apple-local factory gate for a Home
  profile whose adapter is absent.
- **Issue #67** (STD-4) is left open by this change.
