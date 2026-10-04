---
title: 'IOS-HOME-07: Keep Home voice conversations running in the background'
type: 'feature'
created: '2026-10-04'
status: 'done'
baseline_commit: 'feeb475fc113e88ab0a0e496fe557b6e39c06fbe'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/AGENTS.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-04-foreground-reconnect.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-05-audio-start-after-turn.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-ios-home-06-backgrounded-transport-disconnected.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** On iPhone, any non-active scene phase (`.inactive`, `.background`) runs `AppleLifecycleCoordinator.deactivate()`: it stops capture, playback and hands-free, then closes the Home client. Locking the phone or switching apps mid-reply cuts the spoken answer off. A voice conversation cannot continue the way a podcast keeps playing. The app also declares no `UIBackgroundModes` `audio`, so iOS suspends it anyway.

**Approach:** Declare the `audio` background mode. Change lifecycle teardown from "always on background" to "only when no voice work is in flight". While a Home reply is generating or playing, or while a voice session allowed by the decisions below is running, keep the audio session, the voice engine and the Home WebSocket alive. Tear down exactly as today (IOS-HOME-06) once that work ends or the background idle timeout fires. iOS only. macOS behavior does not change.

## Boundaries & Constraints

**Always:**
- Deciding whether to keep work alive is the lifecycle coordinator's job (IOS-HOME-04 serialization stays). It asks one injected predicate, e.g. `VoiceSessionCoordinator.backgroundRetention` → `.none | .reply | .voiceSession`.
- Keep-alive states:
  1. **idle**: nothing in flight. Teardown matches today, IOS-HOME-06 marking included.
  2. **reply**: a Home turn is submitted, streaming, or its audio is pending or playing. This includes the IOS-HOME-05 post-text audio deadline. Keep the transport and output alive. When the reply finishes, the deadline expires or playback fails, run the normal teardown if the app is still not active.
  3. **voiceSession**: hands-free is armed or capture is live, within the scope set by Decision 1. Keep mic and transport alive until the scope or idle timeout (Decision 2) ends it, then tear down.
- `.inactive` with no `.background` (Control Center, notification shade, app switcher peek) never cuts off playback or capture.
- Persistence snapshot (`lifecycleWillDeactivate`) still runs on every non-active phase. A failed snapshot still blocks activation (`deactivationPending`).
- If the transport drops while backgrounded, follow the IOS-HOME-06 rules: mark disconnected, no replay, keep the uncertain turn for Resend/Continue. A background reconnect is allowed only in states reply and voiceSession, uses the IOS-HOME-04 ladder, and never resends.
- `.active` with a live transport kept from the background is a no-op (`hasLiveTransport`). Otherwise behave as today.
- Interruptions and route changes are handled for both output and input: began → stop capture and pause or stop playback, per Decision 5. Old device unavailable (headphones or AirPods removed) → pause output; do not route to the speaker mid-reply.

**Never:**
- No silent audio or keep-alive tricks to stay running while idle. That breaks App Store Guideline 2.5.4.
- No change to the no-replay / uncertain-turn rules, Home claim semantics, or Standard (non-Home) transport.
- No macOS lifecycle change. macOS has no app suspension; macOS `scenePhase` handling stays as is.
- No CallKit/VoIP or push-to-wake.

## Decisions (2026-10-04, approved by Amanda)

1. **Background mic scope:** continue only a turn or hands-free session started in the foreground. Never start the mic from the background; no remote-command push-to-talk.
2. **Background idle timeout:** 60 s after the last voice activity (reply finished, capture ended) while backgrounded with hands-free armed; then the mic stops and teardown runs. Measured with the injected clock.
3. **Lock screen:** Now Playing card titled from the conversation, with Pause/Play (reply playback) and Stop (end the session and tear down). No AirPods push-to-talk. Cleared on teardown.
4. **Other audio:** non-mixable (interrupts podcasts/music) only while backgrounded voice work is running; `.duckOthers` stays in the foreground.
5. **Interruptions:** on began, end the mic session (hands-free disarmed, capture cancelled). On ended with `.shouldResume`, resume unfinished reply playback only if the transport is still alive and the idle timeout has not fired; otherwise tear down if backgrounded.
6. **Size:** keep as one story despite ~3.3k tokens.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Lock mid-reply | reply streaming, `.background` | text + audio finish; then teardown, store disconnected | playback error → teardown |
| Lock before audio starts | text done, audio pending | IOS-HOME-05 deadline still applies; audio plays in background | deadline expires → teardown |
| Background while idle | no turn, hands-free off | immediate teardown (today) | — |
| Control Center pull | `.inactive` only | nothing stops | — |
| Phone call during reply | interruption began, then ended `.shouldResume` | mic session ended; reply playback resumes if transport alive and timeout not fired | transport gone / timeout fired → teardown |
| Hands-free armed in background | reply finished, no new speech | mic and transport kept up to 60 s, then teardown | — |
| Follow-up within 60 s | background, hands-free speech at 30 s | turn submitted, timeout restarts after the reply | — |
| Headphones removed | route change `oldDeviceUnavailable` | reply output pauses | — |
| Stop on lock screen | remote Stop | session ends, teardown, Now Playing cleared | — |
| Socket drops in background | reply in flight | disconnected, uncertain turn kept, retry ladder, no resend | retry exhausted → idle teardown |
| Return to foreground | transport kept | no reconnect, conversation intact | — |

</frozen-after-approval>

## Code Map

- `HermesRelay/Development-Info.plist`, `Release-Info.plist`: no `UIBackgroundModes` today. Add `audio`. `HermesRelay/HermesRelay.entitlements` has only `com.apple.security.device.audio-input` (macOS sandbox), which is fine.
- `HermesRelay/Services/AppleLifecycleCoordinator.swift:63-124`: `process` sends `.inactive/.background/.suspended/.windowDisappeared` all to `deactivate()` (snapshot → `voice.stopForLifecycle()` → `takeHomeClientForLifecycle` → `close`). Split this into snapshot, retention check, and deferred teardown. When retention ends while not active, a new serialized request runs the teardown (no direct call), so IOS-HOME-04 ordering holds.
- `HermesRelay/Views/ContentView.swift:244-259`: maps `scenePhase` to `AppleLifecycleInput`. `.inactive` must no longer mean teardown on iOS.
- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift`: `stopForLifecycle` (820-862) stays the teardown body. Add a retention state, plus a callback/stream when retention returns to `.none`. Hands-free state lives in `isHandsFreeArmed`, `handsFreeStatus`, `isHandsFreeCaptureActive`; reply state in `responseTask`, `audioStreamActive`, `turnDidComplete`.
- `HermesRelay/Services/AudioActivity.swift:62-110` `AppleAudioSessionCoordinator`: set `.duckOthers` in foreground and no mixing while backgrounded voice work runs; add interruption/route event handling.
- `HermesRelay/Services/AppleSpeechInput.swift:223-247`: input interruption observer already ends capture on `.began`; never restart the mic after the interruption ends (Decision 5).
- `ConversationStore`: `hasLiveTransport`, `takeHomeClientForLifecycle`, `scheduleHomeConnectRetry`, `markHomeSubmissionUncertain`. Reuse these; do not fork them.
- No `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` exists yet. Add the iOS-only `NowPlayingController` with the approved card and commands (Decision 3).
- Tests: `HermesRelayTests/AppleLifecycleTests.swift`, `VoiceSessionCoordinatorTests.swift`, `AudioOutputTests.swift`.

## Tasks & Acceptance

**Execution:**
- [x] `HermesRelayTests/AppleLifecycleTests.swift`, `VoiceSessionCoordinatorTests.swift`, `AudioOutputTests.swift`: write tests first and record which fail on the baseline. Cover: reply kept alive in background, then teardown; `.inactive` alone never stops anything; voice session kept up to 60 s, then teardown; idle background tears down as today; interruption ends the mic and resumes the reply; route change pauses output; foreground with a kept transport is a no-op; no replay. Tests run only on macOS (no iOS runtime is installed), so retention must sit behind an injected policy flag, e.g. `backgroundRetentionEnabled`: default `true` on iOS and `false` on macOS, with tests turning it on. Platform audio/MediaPlayer calls go behind small protocols with fakes.
- [x] `HermesRelay/Development-Info.plist`, `Release-Info.plist` (or the `INFOPLIST_KEY_*` iOS-SDK-conditioned build settings, whichever the pbxproj uses for these configs): add `UIBackgroundModes` = [`audio`] for iOS only. The macOS target/SDK stays untouched.
- [x] `VoiceSessionCoordinator.swift`: retention state + end notification, plus idle timeout via the injected clock.
- [x] `AppleLifecycleCoordinator.swift` / `ContentView.swift`: retention-aware deactivate; `.inactive` = snapshot only on iOS.
- [x] `AudioActivity.swift`, audio output: session options, interruption end, and route change, per Decisions 4 and 5.
- [x] `NowPlayingController.swift`: iOS-only conversation-title card with Pause/Play and Stop; cleared on teardown.
- [x] `story-index.yaml`, `sprint-status.yaml`. `CHANGELOG.md` is generated by release-please and is intentionally unchanged.

**Acceptance Criteria:**
- Given a Home reply is playing, when the iPhone locks, then the whole reply plays, and after it finishes the store shows disconnected and Home sees the claim parked.
- Given the app is idle, when it goes to the background, then behavior and tests match IOS-HOME-06.
- Given a background voice session started in the foreground, when 60 s pass with no voice activity, then hands-free is disarmed, capture stops and the normal teardown runs.
- Given backgrounded voice work, when the audio session is configured, then it is non-mixable; given the foreground, then it uses `.duckOthers`.
- Given backgrounded voice work, then a Now Playing card shows the title with Pause/Play and Stop; when teardown runs, then it is cleared.
- Given hands-free is not armed in the foreground, when the app backgrounds, then the mic is never started from the background.
- Given only `.inactive` is reported during voice work, when the lifecycle coordinator handles it, then it snapshots without stopping capture, playback or transport.
- Given an armed hands-free session receives speech within 60 s, when that follow-up completes, then the idle window restarts and no prompt is sent twice.
- Given an interruption ends with `.shouldResume`, when the transport remains live and the timeout has not fired, then unfinished reply playback resumes but the mic stays disarmed; otherwise background teardown runs.
- Given AirPods are removed during reply playback, when the route changes, then playback pauses instead of switching to the speaker and resumes when an output route returns.
- Given a transport drops during a background turn, when the retry ladder reconnects, then the uncertain prompt is not resubmitted and remains available for Resend/Continue.
- Given a macOS build, then lifecycle behavior and tests do not change (retention applies only on iOS).

## Design Notes

Platform facts (Apple docs):
- The `audio` background mode lets the app keep playing or recording after it moves to the background (screen lock included). With no active playback or recording, iOS suspends it as usual: [playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback), [record](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes).
- Starting a recording from the background: Apple documents `cannotStartRecording` as "usually occurs when an app starts a mixable recording from the background" ([doc](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording)), and `.duckOthers` implies `.mixWithOthers`. A non-mixable session that is already active keeps working. [INFERENCE] Starting the mic from a cold background state is not reliable. This is excluded by approved Decision 1.
- A missing plist key shows up as `cannotStartPlaying` ([doc](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartplaying)).
- To appear in Now Playing, the app must use a non-mixable category ([Becoming a now playable app](https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app)).
- Interruptions: `.began`/`.ended` + `.shouldResume` ([doc](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)). Route changes: `oldDeviceUnavailable` → pause ([doc](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)).
- iOS shows the orange mic indicator whenever capture runs; it cannot be suppressed.
- App Review [2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements): background modes only for their intended purpose (audible content). A reviewer must be able to reproduce background playback. Add review notes.
- Networking: an app kept running by the audio mode is not suspended, so the `URLSessionWebSocketTask` keeps working. [INFERENCE] No extra background mode is needed.
- No documented hard time limit while audio is active. Battery is the limit, which is why the approved 60 s timeout matters.

## Verification

**Commands:**
- `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test` on the macOS destination with `-derivedDataPath /tmp/ios-bg-dd`: full suite green, IOS-HOME-04/05/06 tests included.
- `xcodebuild build -destination 'generic/platform=iOS Simulator'` with the same `DEVELOPER_DIR`: succeeds. No simulator runtime is installed, so iOS tests cannot run.

**Manual checks (device gate, cannot run in XCTest):**
- Physical iPhone, Release build: lock mid-reply → full audio; pull Control Center mid-playback → no interruption; hands-free follow-up within 60 s → a new turn; at 60 s idle → mic indicator clears; Now Playing Pause/Play/Stop; podcast pauses during background audio and resumes after; phone call mid-reply → mic ends, reply resumes only on `.shouldResume`; remove AirPods mid-reply → pause until a new route. Check Home logs show no duplicate submit.

## Implementation Notes

- Baseline: every new test fails on feeb475 at compile time, because the retention API (`backgroundRetentionEnabled`, `backgroundRetention`, `enterBackground`, `AudioOutput.pause/resume`, `AudioSessionMixing`, `NowPlayingPresenting`) does not exist there. Behaviorally, baseline `deactivate()` stopped playback and closed the client on every non-active phase, which each retention test asserts against.
- `AppleLifecycleCoordinator`: new `backgroundRetentionEnabled` (default `platformSupportsBackgroundRetention`: iOS `true`, macOS `false`). With it on, `.inactive` only runs `store.lifecycleSnapshot()` (persist only), and `.background` asks `voice.backgroundRetention`. `.none` gives the old teardown. Otherwise it snapshots, marks itself retaining and calls `voice.enterBackground`. When the work ends, the voice callback queues a new serialized `.backgroundWorkEnded` request, which runs the normal `deactivate()` only while still retaining (IOS-HOME-04 ordering holds). `.active` while retaining with `hasLiveTransport` is a no-op apart from `voice.exitBackground()`. Without a live transport it tears down, then activates as today. `.suspended`/`.windowDisappeared` always tear down. A failed snapshot sets `deactivationPending` on every path.
- The store stays lifecycle-active while retained, so Home events, IOS-HOME-05 deadlines and the IOS-HOME-04/06 retry ladder keep running unchanged. The final `lifecycleWillDeactivate()` still marks an in-flight turn uncertain and cancels retries; nothing resends.
- `VoiceSessionCoordinator`: `backgroundRetention` is `.reply` while `responseTask` exists (submit → audio drained), and `.voiceSession` while hands-free is armed or capture is live. Retention changes are tracked with `withObservationTracking`. The 60 s idle timeout (injected `HomeMonotonicClock`) runs only while hands-free is armed with no capture or reply in flight, and restarts after each activity. `armHandsFree`/`beginCapture` refuse while backgrounded (Decision 1). Interruption began → hands-free disarmed, capture cancelled, reply output paused. Ended + `shouldResume` + live transport + timeout not fired → resume. Otherwise end the background work (teardown), or, in the foreground, `stopPlayback()`. Route `oldDeviceUnavailable` → pause.
- `stopForLifecycle` now stops output before awaiting the response task. A paused reply never drains, so the old order would hang teardown. `AudioPlaybackDrain.reset()` releases the waiter.
- `AudioOutput` gained required `pause()`/`resume()` methods (forwarded by the three wrappers; `AppleAudioOutput` pauses the player node and restarts the engine on the reactivated session).
- `AppleAudioSessionCoordinator` conforms to `BackgroundAudioSessionPolicy`. It drops `.duckOthers` (non-mixable) while backgrounded voice work runs and re-applies the category in place. `SystemAudioSessionEventSource` maps interruption and route-change notifications (iOS only). `AppleSpeechInput` is unchanged: its `.began` handler already ends capture, and Decision 5 never restarts the mic, so the coordinator handles `.ended`.
- `NowPlayingController` (new file, added to the pbxproj): title from `HomeCurrentSession.title`, or neutral `Hermes conversation`; never displays the user's prompt. It offers Play/Pause/Toggle/Stop targets and is cleared on every teardown/foreground. It is a no-op on macOS.
- Plist: no `INFOPLIST_KEY_UIBackgroundModes` build setting exists, and Debug uses `GENERATE_INFOPLIST_FILE = NO`, so the key went into both `Development-Info.plist` and `Release-Info.plist`. Both files are shared with the macOS build, which ignores this UIKit-only key. Verified in the built iOS Debug and Release `Info.plist`.
- `CHANGELOG.md` is generated by release-please from PR titles, so it has no manual entry.
- Verification (macOS, Xcode 27.2 beta 2, `CODE_SIGNING_ALLOWED=NO`): full suite, 591 tests, zero failures. The generic iOS Simulator build succeeds. No iOS simulator runtime is available, so iOS tests were not run.
- Device gate still open: the manual checks under Verification need a physical iPhone. App Review notes for 2.5.4 are not written yet.

- Review correction: The first pass's baseline-failure note means the newly added tests do not compile at baseline because the required API is absent; it is not a behavioral-red run. The pre-existing `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery` also fails intermittently on baseline: isolated runs against `feeb475` failed 2/4 before cancellation, confirming the reported full-suite failure is pre-existing/flaky.
- Review correction: tests now pass on the final implementation (591 tests); generic iOS Simulator build passes. The first pass' report of 585 tests / one flaky failure is superseded by final verification.
- Review correction: `AudioOutput` requires explicit `pause()`/`resume()` implementations; it has no default no-op.
- Review correction: Now Playing uses Home's current conversation title when available; otherwise it shows neutral `Hermes conversation`, never a user's prompt.
- Device gate still open: lock mid-reply, Control Center, hands-free follow-up within 60 s, timeout indicator, Now Playing controls, podcast interruption/restoration, phone call and AirPods route-loss checks on Amanda's iPhone. iOS-only real `AppleAudioOutput`, `AppleAudioSessionCoordinator`, and event-source behavior remains device gated. App Review notes for Guideline 2.5.4 remain a release task.

## Spec Change Log

## Review Triage Log

Pass 1 (2026-10-04; blind, edge-case and verification-gap layers):

- Engine restart failure followed by `playerNode.play()` in `AppleAudioOutput.resume`: high, patch (play only while the engine is running).
- A pause before `start(format:)` was dropped by `stopResources`: medium, patch.
- A paused reply in the background had no timeout: medium, patch (the 60 s idle timeout also covers a paused reply).
- Interruption end resumed a reply paused by route loss onto the speaker: medium, patch (pause reason tracked; `newDeviceAvailable` resumes a route-loss pause).
- Returning to the foreground after a lock-screen or interruption pause left the reply paused: medium, patch (resumes on exit from the background).
- Foreground route-loss pause had no resume control: medium, patch (resumes when a device becomes available; Stop still works).
- `withObservationTracking` registrations stacked up: medium, patch.
- `leaveBackground` ran before capture and playback stopped in `stopForLifecycle`: medium, patch (reordered).
- A stale `.background` stranded retained work after `.backgroundWorkEnded` was superseded: medium, patch.
- `MainActor.assumeIsolated` in remote-command handlers: low, patch (hop with `Task`).
- The Now Playing card showed "playing" with no reply playing: low, patch.
- `mixing` was committed before `setCategory` succeeded: low, patch.
- Silent no-op default `pause`/`resume` on the protocol: low, patch (defaults removed).
- `audioSessionEventTask` was never cancelled: low, patch.
- Tautological 60 s assertion: low, patch.
- Missing tests: dead-transport foreground return, socket drop in the background, IOS-HOME-05 deadline in the background, stale `.background`, paused-reply timeout, interruption versus route-loss pause: medium, patch.
- A snapshot failure during retained teardown is not retried until `.active`: maybe-false, defer. Persistence must not be skipped; `deactivationPending` recovers on the next `.active`.
- A held push-to-talk capture in the background has no idle timeout: maybe-false, defer. Recognition finishes on silence; a device check would settle it.
- Real `AppleAudioOutput` pause/resume, `categoryOptions` and `SystemAudioSessionEventSource` are untested: medium, defer to the device gate (iOS-only, no simulator runtime).
- The lock-screen title exposed the first prompt: medium, patch. It now uses the conversation title when available, otherwise the neutral fallback `Hermes conversation`.
- The plist key also sits in macOS bundles (plists are shared): low, rejected. `UIBackgroundModes` is ignored on macOS and the macOS lifecycle is unchanged.
- Spec Q-numbering/status mismatch/App Review notes: the references to unresolved Q numbers and the stale status have been corrected; App Review notes are a release task.
- `story-index` `depends_on` lists only IOS-HOME-06: low, patch (added IOS-HOME-04 and IOS-HOME-05).
