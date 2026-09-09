---
title: 'Render honest iOS turn phases and response delivery'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '1c4724219add65bcde6a9c872bf3c8a8c5ab4631'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The iOS voice coordinator can let a late thinking/status event move the UI backward from buffering or speaking to thinking. Successful responses also fall straight back to Ready instead of exposing the canonical Complete phase, and the audio-file fallback is not marked active while it is being delivered. These gaps make the visible lifecycle disagree with the events Hermes actually sent and can end a response before its audio is ready.

**Approach:** Strengthen the existing typed-event-to-`VoiceState` projection, keeping `ConversationStore` as the text owner and the transport as the event-normalization boundary. Add the settled Complete presentation, guard phase changes against out-of-order processing events, and model both streamed and file-backed audio as part of the same response until terminal delivery is finished.

## Boundaries & Constraints

**Always:** Consume normalized Hermes events; show only phases justified by observed events; preserve one coherent assistant response when text and audio arrive together; preserve completed text when playback fails; keep diagnostics content-safe; keep iOS capture bound to the verified session from Story 1.1. iOS may omit `heard` because tap-to-speak does not observe that phase.

**Never:** Change the Hermes wire contract; invent upload, undo, usage, compression, or remote-interrupt operations; replay a turn; make views parse frames or infer relay state; replace, duplicate, or paraphrase Hermes response text; imply audio is playing on a display-only state; alter TUI behavior or unrelated history/profile work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| STREAMED_RESPONSE | Accepted turn; capture, transcription, thinking, audio start/chunk/end, turn complete | `listening → transcribing → thinking → buffering → speaking → complete`; text and audio belong to one assistant response | No premature phase or completion |
| LATE_PROCESSING_EVENT | Buffering or speaking, then status/thinking delta | Current output phase is retained | Ignore the stale phase hint safely |
| FILE_AUDIO_FALLBACK | Text completes; audio-file start, turn complete, then audio-file end | Text remains visible; completion waits for file delivery and playback finish | If decode/playback fails, report audio unavailable and retain text |
| TEXT_WITHOUT_AUDIO | Completed response text with no playable audio | Complete text remains visible; voice state reports unavailable playback | Do not claim speaking or silently discard text |
| STALE_OR_UNKNOWN_EVENT | Event for another/stale turn, or unknown event type | Active phase and response do not mutate | Optional diagnostics contain no prompt, response, token, or audio data |

</frozen-after-approval>

## Code Map

- `HermesRelayIOS/Models/SessionModels.swift` -- canonical iOS voice phase values and presentation semantics.
- `HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift` -- owns capture, playback, and normalized-event phase projection.
- `HermesRelayIOS/Views/AmbientHUD.swift` -- maps phases to the ambient label, tint, caption, and visualizer.
- `HermesRelayIOS/Views/VoiceStatusView.swift` and `HermesRelayIOS/Views/VoiceControl.swift` -- keep settled Complete distinct from active response/capture states.
- `HermesRelayIOS/Views/ContentView.swift` -- supplies the coordinator's response activity to the shared HUD while playback drains.
- `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift` and `HermesRelayIOSTests/HermesRelayIOSTests.swift` -- deterministic lifecycle and presentation coverage.

## Tasks & Acceptance

**Execution:**
- [x] `HermesRelayIOS/Models/SessionModels.swift` -- add Complete and shared phase predicates/mappings -- prevent duplicated, contradictory UI semantics.
- [x] `HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift` -- enforce monotonic output phases, active file-audio boundaries, terminal completion, and playback-failure reporting -- keep presentation honest without changing the protocol.
- [x] `HermesRelayIOS/Views/AmbientHUD.swift`, `HermesRelayIOS/Views/VoiceStatusView.swift`, `HermesRelayIOS/Views/VoiceControl.swift` -- render Complete and keep it non-active -- make the settled response actionable and visually calm.
- [x] `HermesRelayIOS/Views/ContentView.swift` -- keep the shared HUD active through playback drain and settle it with the coordinator -- prevent the shell from declaring the response idle early.
- [x] `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift`, `HermesRelayIOSTests/HermesRelayIOSTests.swift` -- cover the matrix and phase projection with fake clients/output -- catch regressions without a live relay.

**Acceptance Criteria:**
- Given an accepted turn and normalized lifecycle events, when each event arrives, then the iOS phase advances only when warranted and ends in visible Complete after successful response delivery.
- Given streamed response text and audio, when deltas/chunks arrive, then the UI presents one coherent assistant response and never invents or duplicates content.
- Given completed text and unavailable audio, when playback cannot start or fails, then the text remains visible and the UI identifies audio as unavailable without showing Speaking.
- Given a stale, unknown, or differently identified event, when it is received, then the active phase and response remain unchanged and any diagnostic is content-safe.

## Implementation Notes

- `VoiceState.complete` is a stable presentation state reached only after `turnComplete` and all active PCM/file output have drained. Capture and response activity now derive from shared state predicates rather than view-local switches.
- PCM and file-backed audio are tracked independently; a terminal turn event waits for either stream to finish. A non-empty `messageComplete.failureReason` stops playback, preserves the store-owned assistant text, and reports the failure without presenting Speaking.
- The Hermes wire contract is unchanged. The URLSession transport now keeps a file-backed turn stream open when `turnComplete` precedes `audioFileEnd`; stale processing hints are ignored after output begins, and unknown or differently identified events remain content-safe and cannot mutate the active turn.
- Local verification used the installed Xcode 26.5 SDK with signing disabled because the unsigned local test/app run lacks the Keychain entitlement. The simulator smoke launch therefore showed a content-safe Keychain entitlement diagnostic; it showed `Not connected` and `Ready`, and did not attempt a turn. The combined Epic 1 iOS device validation pass remains required for microphone, Keychain, speaker-route, and live playback behavior; see `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md`.

## Spec Change Log

## Review Triage Log

- BH-01 — `false` — The required finding-floor arithmetic is not a defect: the review artifact was 56,847 bytes, so `floor(sqrt(55.514648) + 1) = 8`, and the reviewer supplied more than eight findings.
- BH-02 — `false` — The duplicate BMAD additions were caused by the review artifact being manually appended with files that were already staged; the repository never contained duplicate files, and the regenerated diff contains one addition per artifact.
- BH-03 — `medium`, `patch` — A turn-complete event with text but no delivered audio could previously settle successfully; the coordinator now requires non-empty output delivery and reports the standard playback-unavailable failure while retaining text.
- BH-04 — `medium`, `patch` — The error path could leave queued output running; it now clears active delivery, stops the output, and only then publishes the server failure if the response generation is still current.
- BH-05 — `false` — `URLSessionHermesSessionClient.handleTextFrame` rejects a frame whose root or nested `turn_id` differs from the active turn before normalization; direct typed fakes do not bypass that production boundary.
- BH-06 — `medium`, `patch` — Late audio, error, interruption, timing, and completion work could mutate a terminal response; terminal guards, generation checks after awaited output calls, and the store's late-event guard now keep `Complete`, `Interrupted`, and `Failed` stable.
- BH-07 — `false` — The current fallback contract is WAV; unsupported or malformed file bytes fail through `WAVAudioDecoder` and surface playback unavailable rather than claiming unsupported audio is playing. The content type remains part of the normalized event.
- BH-08 — `medium`, `defer` — The rail can lose its live assistant identity after `ConversationStore` applies `turnComplete` even while playback drains, but that lifecycle predates this slice and needs a separate rail/store change; recorded in `deferred-work.md`.
- BH-09 — `medium`, `patch` — The file test's output completed immediately and did not prove the drain boundary; `StartGatedAudioOutput` now gates `finish`, and the test asserts `Speaking` before release and `Complete` afterward.
- BH-10 — `medium`, `patch` — Existing turn-complete-only fixtures encoded a successful no-audio turn; they now expect playback-unavailable failure, and the explicit text-only test verifies the transcript remains visible.
- BH-11 — `low`, `patch` — Local design and smoke documentation still described successful response completion as `idle`/`Ready`; both now document `Complete` and the playback-failure branch.
- BH-12 — `medium`, `defer` — Validation on the available Xcode 26.5 SDK cannot establish the repository's Xcode 26.6-or-newer baseline; the environment limitation and combined Epic 1 device pass are recorded in `deferred-work.md`.
- VG-01 — `medium`, `patch` — The prior late-event test covered `Speaking` only; a matching `Buffering` fixture now proves status/thinking hints cannot regress an output that has not reported readiness.
- VG-02 — `medium`, `patch` — The failure test had no active output to stop; it now starts and appends audio, then asserts `stop` occurred and `finish` did not.
- VG-03 — `medium`, `patch` — The file fixture did not gate playback drain, and the real URLSession client closed its stream at `turnComplete`; the fixture now gates `finish`, while transport completion is deferred until `audioFileEnd`.
- VG-04 — `low`, `patch` — A normalizer test now proves `message.complete.failure_reason` is preserved as typed failure metadata without inventing or duplicating response text.
- VG-05 — `medium`, `patch` — A production file fallback could lose bytes when `turnComplete` preceded `audioFileEnd`; the transport now keeps the continuation open and the reordered URLSession test exercises that sequence.
- VG-06 — `low`, `patch` — `TimelineView` previously continued ticking after the mode became `Complete`; its schedule and phase are now paused for non-animated modes.
- EC-01 — `medium`, `patch` — A no-audio `turnComplete` could previously reach `Complete`; the coordinator now reports playback unavailable and preserves the assistant text.
- EC-02 — `medium`, `patch` — Zero-length decoded WAV payloads were not rejected before output; the coordinator now rejects empty PCM and reports playback unavailable.
- EC-03 — `medium`, `patch` — An awaited PCM append could resume after interruption and write `Speaking`; post-await generation/terminal guards now discard that stale result.
- EC-04 — `medium`, `patch` — File start, append, and finish could similarly resume after interruption; each awaited boundary now rechecks the active response generation.
- EC-05 — `medium`, `patch` — Late terminal output events could mutate the coordinator or store; coordinator terminal guards and `ConversationStore`'s completed/interrupted guard now reject them.
- EC-06 — `medium`, `patch` — The URLSession file-order boundary had the same turn-complete-before-file-end defect; the transport now defers stream closure until the file end event.
- EC-07 — `medium`, `patch` — A message-completion failure could race an awaited output stop; the post-await current-generation check now prevents a stale failure from changing a newer or interrupted turn.
- EC-08 — `medium`, `defer` — Unbounded `audio_file_chunk` accumulation is real but pre-existing and needs a deliberate payload limit/policy; recorded in `deferred-work.md`.
- EC-09 — `low`, `patch` — Partial file data could survive an unsuccessful response into a later attempt; new-turn, transport-failure, and playback-failure paths clear the file buffer.
- EC-10 — `low`, `patch` — Whitespace-only failure reasons could publish a blank failure state; failure reasons are trimmed and empty values are ignored.
- EC-11 — `low`, `patch` — The completed HUD rings/orb could still animate despite a non-animated mode; the timeline is now paused and its phase fixed for `Complete`, `Interrupted`, `Failed`, and `Ready`.
- EC-12 — `medium`, `patch` — A same-generation abort/interruption after `Complete` could regress the settled state; terminal guards now reject it.
- EC-13 — `medium`, `patch` — Coverage lacked explicit no-audio, buffering-regression, active-stop, file-drain, and terminal-late-event scenarios; those deterministic tests now exist.

## Design Notes

`Complete` is a stable presentation state until the next local capture or send action; it is not a new Hermes wire event. `heard` remains an allowed product phase for surfaces that observe it, but this tap-to-speak client does not manufacture it. A local stop/interruption remains distinct from successful Complete.

## Verification

**Commands:**
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' -only-testing:HermesRelayIOSTests/VoiceSessionCoordinatorTests -only-testing:HermesRelayIOSTests/HermesEventNormalizerTests -only-testing:HermesRelayIOSTests/URLSessionHermesSessionClientTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- 78 focused tests passed.
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' -only-testing:HermesRelayIOSTests/ConversationStoreTransportTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- 16 focused transport/store tests passed.
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- iPhone 17 Pro, iOS 26.5; 213 tests passed.
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` -- iOS simulator build succeeded.
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` -- 213 tests passed.
- `xcodebuild -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` -- macOS target build succeeded.

**Manual checks (if no CLI):**
- Follow the voice smoke plan in `docs/plans/2026-08-30-ios-voice-interface-testing-plan.md`; verify the selected Profile remains visible, phases do not regress, Complete is visible after delivery, and playback failure leaves the response text readable without recording private content.
