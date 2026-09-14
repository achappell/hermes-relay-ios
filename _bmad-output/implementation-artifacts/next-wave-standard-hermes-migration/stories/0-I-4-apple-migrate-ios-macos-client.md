---
title: '[Apple] Migrate the iOS/macOS client'
type: 'feature'
created: '2026-09-14'
status: 'draft'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** The Apple client currently sends fork-only `hello`/`turn`/`interrupt` frames, personal bearer credentials, and same-socket PCM. It has no adapter for Home’s planned schema-1 `/api/v1/bridge/ws` boundary, so the target migration cannot be verified without risking local Profile, history, presentation, audio, interruption, or recovery behavior. The public Home adapter is not live.

**Approach:** Add an explicit Apple-local Home bridge route and configuration seam behind `HermesSessionClient`, using an injectable fake Home bridge for implementation and evidence until the public endpoint exists. Consume Home’s opaque handle, Device credential, route/status separation, JSON-RPC envelope, normalized Standard events, and separate audio notifications; retain the current client as an explicit rollback path. Do not call Home methods on vanilla Hermes `/api/ws`, expose a Hermes bearer, or claim live route integration before the Home adapter is served.

## Boundaries & Constraints

**Always:** Consume only the Home-approved route and opaque conversation handle; freeze route, Household, bridge, and turn identity for each turn; expose readiness only after Home authorization and bridge/session binding are verified; keep one receive owner per Home control stream and one owner per audio stream; preserve cumulative text, turn correlation, verified PCM metadata, terminal ordering, local Profile UUID/history/Keychain separation, native capture/playback, and confirmed-versus-unconfirmed interruption state. Reconnect only through Home with fresh authorization/readiness and preserve the unresolved-turn marker. Require a fresh explicit user action after uncertainty. Treat Standard timing as absent unless a verified playback clock or duration supplies it; network arrival is never timing authority. Use only the approved Device credential boundary and content-safe diagnostics.

**Never:** Put raw Standard/Home frames in `ConversationStore` or SwiftUI, add a second Hermes parser, invent or claim a live Home route, send Home methods directly to vanilla `/api/ws`, send a personal or server-held Hermes bearer to the endpoint, persist a Device credential outside Keychain, switch routes during an active or uncertain turn, replay an uncertain turn, silently emulate missing prompts/commands/timing, or change the sibling Home/TUI repositories.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Ready text and voice turn | Fake Home bridge; approved Device credential; opaque handle; ready bridge/session; normalized text and sidecar PCM | Native text and voice surfaces retain current phases, text replacement, audio format, and playback-drain completion semantics | Unusable Home readiness or audio metadata is typed unavailable before false completion |
| Standard timing absent | Ready Standard session with no speech-timing capability | Timing capability is visibly absent to evidence/state; captions use existing playback/duration behavior | Never derive timing from frame arrival or transcript timestamps |
| Confirmed interrupt | Active turn with advertised interrupt; terminal interruption arrives | Native playback stops, stale events are discarded, and the surface reports Interrupted only after terminal confirmation | Request/acknowledgement without terminal confirmation is not completion |
| Route loss or uncertain delivery | Active/uncertain turn loses Home transport | Home reconnects through an approved same-identity route after fresh authorization/readiness; text remains recoverable and the user gets an explicit fresh resend action | No path switch during active/uncertain delivery or automatic resend; unconfirmed delivery remains unconfirmed |
| Reversible configuration conversion | Existing profile, local history, legacy credential, and new route metadata | Profile identity, device identity, history, draft, and uncertainty marker survive; legacy source remains until verified rollback is possible | Failed conversion leaves the legacy source usable and reports a safe actionable error |

</intent-contract>

## Code Map

- `HermesRelay/Services/HermesSessionClient.swift:3-15` -- stable async client seam; `false` interruption delegates fallback to the caller.
- `HermesRelay/Models/SessionModels.swift:176-246,289-307` -- `SessionMetadata`, `HermesTurnBinding`, audio/timing values, and normalized `HermesEvent`.
- `HermesRelay/Services/URLSessionHermesSessionClient.swift:33-57,75-180,222-421` -- current fork client and rollback behavior: one reader, generation guards, audio gates, interruption confirmation, and transport cleanup.
- `HermesRelay/Services/HermesEventNormalizer.swift:17-337` -- existing JSON/binary normalization, cumulative-preview replacement, PCM metadata, interruption, and timing fallback; Standard translation ends here or immediately before it.
- `HermesRelay/ViewModels/ConversationStore.swift:30-131,163-358,375-507` -- verified binding, client construction, profile switching, bounded reconnect, uncertain-turn persistence, and no-replay recovery.
- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift:469-576,731-840,891-1238` -- Apple capture binding, interruption handoff, native PCM playback, playback drain, and playback-clock/duration timing.
- `HermesRelay/Models/RelayProfile.swift:29-95`, `RelayProfileCollection.swift:3-44`, `HermesRelay/Services/RelayConfigurationStore.swift:24-177`, `SecureValueStore.swift:4-70` -- profile schema, selection, per-profile Keychain credentials, and copy/verify legacy migration.
- `HermesRelay/Services/ConversationPersistence.swift:3-90` -- per-profile messages, draft, and `unconfirmedTurnText`; do not consume this reversible migration seam.
- `HermesRelay/Services/WebSocketConnection.swift:3-157` -- injectable WebSocket boundary; extend fakeable ownership for the Standard JSON socket and audio sidecar without adding UI readers.
- `HermesRelay/Services/DeviceDiscoveryClient.swift:104-143` -- Home configuration publication only; it is not a turn transport.
- `HermesRelayTests/URLSessionHermesSessionClientTests.swift:204-299,363-653,698-917`, `ConversationStoreTransportTests.swift:125-205,482-713`, `ConversationStoreReconnectTests.swift:7-181`, `RecoveryTests.swift:7-100`, `RelayConfigurationTests.swift:298-542`, `ConversationPersistenceTests.swift:61-124`, and `VoiceSessionCoordinatorTests.swift:768-878,944-1073,1367-1477,2777-2888` -- reusable fakes and existing safety contracts; no Standard/Home fixture exists yet.
- `Hermes Relay.xcodeproj/project.pbxproj:167-185,259-294,392-408`, `.github/workflows/ci.yml:17-89`, `docs/workflow.md:33-87` -- source membership and the actual iOS/macOS build-test ladder.

## Tasks & Acceptance

**Execution:**

- `HermesRelay/Models/SessionModels.swift`, `HermesRelay/Models/RelayProfile.swift`, `HermesRelay/Models/RelayProfileCollection.swift`, `HermesRelay/Services/RelayConfigurationStore.swift`, and `HermesRelay/Services/SecureValueStore.swift` -- add versioned, explicit Home/Standard/rollback route and credential metadata with idempotent conversion keyed by stable profile identity; retain legacy data until verified -- prevents an endpoint-string guess from retargeting history or losing rollback.
- `HermesRelay/Services/StandardHermesSessionClient.swift` and `WebSocketConnection.swift` -- implement the approved route adapter behind `HermesSessionClient`, using `/api/ws` JSON-RPC plus `/api/audio/speak-stream` PCM or the versioned Home bridge envelope, with opaque Home handle/device credential, one reader per socket, correlation, typed readiness/unavailability, and normalized events -- keeps wire details out of Apple presentation.
- `HermesRelay/Services/HermesEventNormalizer.swift` -- extend only the existing normalization boundary for Standard/Home event names, cumulative previews, verified audio metadata, interrupt terminal state, and explicit timing absence -- avoids a second Hermes dialect and false timing.
- `HermesRelay/ViewModels/ConversationStore.swift` and `ReconnectPolicy.swift` -- construct the selected route before a turn, preserve the legacy client as explicit rollback, require readiness, and retain current close/reconnect plus unconfirmed/fresh-resend behavior on uncertain delivery -- prevents silent path changes and replay.
- `HermesRelayTests/StandardHermesSessionClientTests.swift`, `HermesRelayTests/ConversationStoreTransportTests.swift`, `HermesRelayTests/ConversationStoreReconnectTests.swift`, `HermesRelayTests/RecoveryTests.swift`, `HermesRelayTests/RelayConfigurationTests.swift`, and `HermesRelayTests/ConversationPersistenceTests.swift` -- add deterministic dual-socket fake-bridge coverage for readiness, credential non-leakage, text, PCM, audio failure, interrupt confirmation, route loss, timing absence, idempotent conversion, rollback, and no replay -- proves the matrix without a live endpoint.
- `HermesRelayTests/VoiceSessionCoordinatorTests.swift` and `Hermes Relay.xcodeproj/project.pbxproj` -- preserve native capture, playback drain, interruption, lifecycle handoff, timing fallback, and add new source/test membership -- keeps iOS and macOS targets using the same Apple-local lifecycle rules.
- `_bmad-output/implementation-artifacts/next-wave-standard-hermes-migration/stories/0-I-4-apple-migrate-ios-macos-client-validation.md` -- record fake-bridge results plus live iOS/macOS text, voice, reconnect, route/rollback, interruption, timing-absence, and content-safe evidence using the existing manual plan -- makes this surface’s gate independently reviewable.

**Acceptance Criteria:**

- Given an existing selected Apple Profile, when the app converts it to an approved Home/Standard route, then the native surface preserves Profile identity, device identity, local history, draft, and uncertainty state while keeping the legacy source available for explicit rollback.
- Given a route is selected and its session is ready, when a user sends a typed or voice turn, then the native conversation surface receives the same normalized text and terminal meanings, and the native audio surface plays verified PCM and settles only after the turn and playback lifecycles both finish.
- Given the Standard path has no authoritative speech timing, when the native surface renders the response, then it reports timing as unavailable or uses the existing verified playback/duration fallback and never presents network arrival as timing evidence.
- Given a user interrupts an active turn, when the approved path confirms the terminal interruption, then the native surface stops playback, reports the confirmed interruption, and does not apply stale text or audio; without confirmation, it uses the existing explicit close/reconnect fallback and leaves delivery unconfirmed.
- Given transport or route loss occurs before or during a turn, when recovery runs, then the selected path reconnects only after readiness, the native surface remains actionable, and an uncertain submission requires a fresh explicit user action with no automatic replay or route switch.
- Given the shared fake and live validation scenarios pass, when the implementation is built, then the `HermesRelay` scheme passes focused XCTest, iOS Simulator build/test, and macOS build/test, with evidence containing no prompts, response text, credentials, raw frames, or audio captures.

## Spec Change Log

## Review Triage Log

- 2026-09-14: The migrated plan-reviewer paused implementation. The Home bridge endpoint/envelope and route identity contract are still open upstream, and the plan also lacks implementable credential conversion, readiness, reconnect, dual-socket ordering, audio validation, prompt/command capability handling, timing absence, interruption, route-loss, lifecycle, and pinned validation details. See the local validation record for the complete reviewer result and resume conditions.

## Design Notes

The adapter owns the awkward join between two Standard sockets. A control terminal event must not close the normalized stream while declared response audio is still being delivered; audio failure leaves readable text alive. The route identity is a configuration fact, not a UI inference: the current legacy client remains selectable, while a Home/Standard route is frozen for the whole turn and only reconsidered after the turn is settled or explicitly marked uncertain.

The existing coordinator already expresses the desired timing rule: validated timing events, verified PCM duration, and `AudioOutput.playbackPosition()` are acceptable sources. The new adapter must report the Standard baseline’s timing absence and let that coordinator behavior stand.

## Verification

**Commands:**

- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: iOS Simulator build succeeds.
- `simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')" && test -n "$simulator_id" && xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination "platform=iOS Simulator,id=$simulator_id" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: focused and full iOS XCTest pass against the first available iPhone Simulator.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: macOS build succeeds.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: macOS XCTest pass.

**Manual checks:**

- On iOS and macOS, exercise the existing voice plan with the approved route: readiness before capture, one text turn, one spoken turn with sidecar PCM, confirmed interruption, route loss/reconnect, explicit rollback, and one fresh resend after uncertainty.
- Confirm the UI never reports Speaking/Complete from network arrival alone; timing evidence is absent or tied to verified playback/duration.
- Review the validation record and diff for bearer tokens, prompt/response content, raw frames, PCM/audio captures, generated build files, and changes outside this repository.

## Auto Run Result

Status: blocked
Planning boundary: paused after planning and the blocking plan review.
Blocking condition: Home Story 2 must pin the approved Apple-facing bridge contract before implementation can safely resume.
