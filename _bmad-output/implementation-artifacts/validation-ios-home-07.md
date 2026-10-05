# IOS-HOME-07 Validation

Date: 2026-10-04
Baseline: `feeb475fc113e88ab0a0e496fe557b6e39c06fbe` (`fix/ios-home-foreground-reconnect`)

## Automated gates

- **macOS XCTest:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bg-dd CODE_SIGNING_ALLOWED=NO` — passed, 591 tests, 0 failures. Includes IOS-HOME-04/05/06 coverage and IOS-HOME-07 lifecycle/voice tests.
- **iOS Simulator build:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild build -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ios-bg-dd-ios CODE_SIGNING_ALLOWED=NO` — passed. No iOS Simulator runtime is installed; no iOS tests were run.
- **Test-first baseline check:** copied the new voice/output test files into a detached worktree at `feeb475` and ran `xcodebuild build-for-testing`. It failed as expected because the new APIs/types (`NowPlayingPresenting`, `BackgroundAudioSessionPolicy`, `AudioSessionEventSource`, `AudioOutput.pause/resume`, `AudioSessionMixing`) do not exist on baseline. This confirms the tests are red against baseline at compile time, not that an existing behavior assertion ran and failed.
- **Pre-existing flaky baseline test:** `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery` failed in 2 of 4 isolated baseline runs before that loop was stopped; both failed assertions showed `reconnecting(attempt: 1, of: 5)` instead of connected. The full final suite passed.

## Follow-up: route loss and Now Playing state

- **macOS XCTest:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bg-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO` — passed, 593 tests, 0 failures. The three new coordinator regressions also passed independently.
- Two preceding default-parallel full-suite runs hit the known flaky `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery`: `XCTAssertEqual failed: ("reconnecting(attempt: 1, of: 5)") is not equal to ("connected")` at line 198 and `XCTAssertTrue failed` at line 199. Its isolated rerun passed; the serialized full suite passed.
- **iOS Simulator build:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild build -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ios-bg-sim-dd CODE_SIGNING_ALLOWED=NO` — passed. The asset catalog warned that the 60x60@2x iPhone icon, 76x76@2x and 83.5x83.5@2x iPad icons, and 1024x1024 App Store icon are missing.
- **Signed generic iOS device build:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild build -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS' -derivedDataPath /tmp/ios-bg-device-dd CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES` — passed with the existing Apple Development identity and local provisioning profile `e65ff3bc-f036-4bb8-8465-7a057c1e2036`; no provisioning or entitlement errors. No install or launch occurred during the build gate; the later install-only verification is recorded below.

## Install-only device verification

- Amanda approved the install-only update. The signed development build `0.6.0` (build `1`) was installed successfully on the paired iPhone 17 Pro Max running iOS `27.0.1` (`com.achappell.HermesRelay`).
- After installation, the app was not launched or opened, and no Home requests or household traffic were generated.
- `devicectl` reported a new app data-container UUID relative to pre-install metadata. UUID values are omitted. Apple TN2285 states that an app update changes the absolute app-container path, so a changed UUID is expected and alone does not indicate data loss. Apple says `Library` except `Library/Caches` is guaranteed to be preserved across updates: [Apple TN2285 — Testing iOS App Updates](https://developer.apple.com/library/archive/technotes/tn2285/_index.html).
- `HermesRelay/HermesRelayApp.swift` resolves `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` (falling back to `temporaryDirectory` only if unavailable), appends `HermesRelayIOS`, and uses that root for the persisted profile, Home configuration and pairing records, diagnostics reports, and per-profile conversations. With the Application Support path, these files are within `Library` and preservation is expected under the documented update contract. Actual settings and saved state remain unverified until Amanda opens the app.
- No physical behavior checks were run during installation. The nine checks below and App Store Review notes for Guideline 2.5.4 remain open release gates.

## Device incident: accepted Home turn received no response (2026-10-04)

Amanda reported no response after the install. Read-only evidence, in CDT:

- **iPhone unified log (observed):** the app launched at 19:31:49, the Home configuration requests returned HTTP 200, and the bridge WebSocket upgraded (HTTP 101) at 19:31:51. Capture ran from 19:32:32 to 19:32:38. The client cancelled that WebSocket at 19:33:10.224, about 32 s after submission. The next reconnect upgraded and then failed with `Socket is not connected`; a later reconnect became ready. No reply audio-session activation or playback appeared.
- **Privacy-safe device journal (observed; event names only):** `home bridge request completed method=prompt.submit` at 19:32:38.356, `home connect open result=unavailable reconnect_required` at 19:33:10.855, and `home connect reconnect result=ready unresolved_turn=true` at 19:33:10.915. The journal has no explicit timeout event; the `controlTerminalMissing` path does not write to it.
- **Home diagnostics (observed):** `request_observed` and `upstream_submit_outcome outcome=accepted` at 19:32:38.6. The connection closed at 19:33:10.56, the reconnect at 19:33:11 was `rejection_generated`, and the next connection became ready.
- **Standard (observed):** prompt accepted at 19:32:38.261. Turn finished at 19:33:40.98 with `status=complete duration=62.7s`. At 19:33:19, Standard also logged an approval request that was not sent because the attached client predates server-to-client requests; a terminal tool then returned `BLOCKED`. That is a separate capability gap. It is not established as the reason audio was absent, and this fix does not address it.
- **Inference (strong, unconfirmed):** the client's 30 s `HomeTurnAudioDeadlines.controlTerminal`, measured from acceptance, fired before Standard finished. The app then marked the submission uncertain and reconnected, so the 62.7 s reply was not delivered. The 19:33:10 close, about 31.6 s after `prompt.submit` completed, matches that timer; no app-level log records the timer firing.

### Fix: control-terminal deadline 30 s to 120 s

- `HermesRelay/Models/HomeBridgeModels.swift`: `HomeTurnAudioDeadlines.default.controlTerminal` changes from 30 s to 120 s. The value matches Home's `DEFAULT_CLIENT_RECONNECT_GRACE_SECONDS` (120 s), the period Home keeps an in-flight client claim after the client disconnects, so the phone no longer abandons a turn Home still treats as live. A turn with no control terminal still fails through the existing `controlTerminalMissing` path, without replay. This supersedes the 30 s value in the IOS-HOME-05 and 0-I-4 specs.
- Red/green regressions use a fake clock and fake Home client, with no live Home:
  - `testAcceptedHomeTurnThatFinishesAfterSixtyThreeSecondsDeliversWithoutReplay`: before the fix, it failed with `controlTerminalMissing`, coordinator state `failed("transport_timeout")`, and no audio delivered. After the fix, it passes: the reply completes and plays after 63 s with exactly one submission.
  - `testAcceptedHomeTurnWithNoTerminalStillFailsAtTheControlDeadline`: before the fix, it failed because the timeout fired before 119 s. After the fix, it passes: there is no timeout at 119 s, `controlTerminalMissing` occurs at 120 s, and there is one submission.
- **macOS XCTest:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bg-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO` passed with 595 tests and 0 failures.
- **Signed generic iOS device build:** the same command as above passed with the existing Apple Development identity and team provisioning profile. The fixed build was not installed or launched, and no Home traffic was generated.
- **Still open:** confirming on device that a slow turn now delivers, including whether the fixed build removes the no-response symptom, requires an approved physical test.

### Fixed build install-only handoff

- **Artifact provenance:** the signed device artifact (`/tmp/ios-bg-device-dd/.../Hermes Relay.app`) was signed at 19:46:15 CDT by team `37CAHGRH45`, bundle `com.achappell.HermesRelay`, version `0.6.0` (build `1`). The only app-target source changed by commit `185418a6a9e65534ec2edbd50b27fd76693e6afa`, `HermesRelay/Models/HomeBridgeModels.swift`, was last modified at 19:45:08, before signing. No app source or project file was modified after the artifact was built, and the working tree was clean at that commit. The artifact therefore contains the fix's app sources; it was not rebuilt.
- `devicectl device install app` succeeded on Amanda's paired iPhone 17 Pro Max. A read-only `devicectl device info apps` check then reported Hermes Relay `com.achappell.HermesRelay` `0.6.0` (`1`) installed as a developer app with an accessible data container.
- The app was not launched or opened. App contents were not inspected, and no Home traffic was generated. The fix now awaits Amanda's retest of a slow Home turn. The device checks below and App Store Review notes for Guideline 2.5.4 remain open.

### Follow-up: activity-based control deadline with Home turn keep-alives

Amanda approved replacing the fixed acceptance-based deadline when Home can prove that a turn is still running. Home forwards text, reasoning, status, terminal, and structured-prompt events, but not `tool.*`. As a result, a long tool call or model wait can be silent to the client.

- **Contract** (Home `feat/home-turn-keepalive` @ `1babeb6`): the client opts in on the WebSocket upgrade with the header `X-Hermes-Home-Client-Features: turn_keepalive` (`HomeBridgeClientOptIn` in `HermesRelay/Services/HomeBridgeSessionClient.swift`). Home rejects unknown open/reconnect params, so the opt-in is a header, which older Homes ignore. Only for opted-in clients, Home's ready reply carries `"turn_keepalive": true` in its capabilities, and Home sends turn-scoped `turn.alive` events every 15 s while a turn runs, with payload `{"phase":"running"|"awaiting_input"}`. Ready replies to older clients stay unchanged. This matters because older iOS builds, including the installed `0.6.0` (`1`) build, reject any unknown capability key.
- **Client behavior:** if the capability is present, the control deadline is idle-based. It expires after 45 s (`controlIdle`) with no current-turn activity and restarts on any current-turn Standard event, `turn.alive`, scoped activity, or Home audio start, PCM, or terminal event. The idle clock is suspended while a structured prompt is pending or the keep-alive phase is `awaiting_input`. An 1800 s backstop (`controlBackstop`) from acceptance is never extended. Without the capability, the fixed 120 s `controlTerminal` from acceptance still applies. Every expiry uses the existing `controlTerminalMissing` and mark-uncertain path, without replay. `turn.alive` is never rendered. All values come from `HomeTurnAudioDeadlines`.
- **Tests** (fake clock and fake Home client): `testKeepaliveTurnRunningFiveMinutesDeliversOnceWithoutReplay`, `testKeepaliveTurnSilentForTheIdleDeadlineIsMarkedStuck` (44 s no timeout, 45 s timeout), `testPendingHomePromptSuspendsTheIdleDeadline` (no timeout at 300 s; backstop at 1800 s), `testKeepaliveBackstopFiresDespiteContinuousKeepalives`, `testURLSessionClientOptsIntoTurnKeepalivesAndDecodesTurnAlive` (header and exact `params.event` envelope), and `testWireCapabilitiesDecodeTurnKeepaliveOnlyWhenHomeAdvertisesIt`. The existing 63 s and 120 s fixed-deadline tests still pass.
- **macOS XCTest (serialized):** passed with 601 tests and 0 failures. The preceding serialized run had one failure, the known flaky `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery` (`reconnecting(attempt: 1, of: 5)` instead of `connected`).
- **Signed generic iOS device build:** passed with the existing Apple Development identity and team provisioning profile. Not installed or launched; no Home traffic.
- **Still open:** the keep-alive path needs a deployed Home with the matching change and an approved device retest. The installed `0.6.0` (`1`) build does not contain this follow-up.


## Device-only checks for Amanda

On a physical iPhone: check 1 uses the installed Development build `0.6.0` (`1`); checks 2–10 require a Release build.

1. On the installed fixed build `0.6.0` (`1`), submit one benign Home turn and keep the app connected in the foreground for up to 120 seconds. If the turn runs longer than 30 seconds, verify that the response text and audio arrive exactly once, with no second submission or replay. A turn that completes in under 30 seconds does not exercise the fixed timeout. You do not need to share the prompt text, and no app contents need to be read.
2. Lock the screen during a generated reply; verify the entire reply plays, then Home disconnects/parks the claim.
3. Open Control Center during playback and during hands-free capture; verify `.inactive` alone does not stop either.
4. With hands-free armed in the foreground, lock the phone and speak a follow-up within 60 seconds; verify the new turn is submitted exactly once.
5. Leave hands-free idle in the background for 60 seconds; verify capture stops and the orange microphone indicator clears.
6. Use lock-screen Now Playing Pause/Play and Stop; verify Pause/Play control output, Stop ends the session and clears the card.
7. Play a podcast, then start background voice work; verify the podcast is interrupted and resumes after Hermes releases the session.
8. Take a phone call during reply playback; verify mic session ends and unfinished reply resumes only when the interruption ends with `.shouldResume` and transport/timeout conditions still hold.
9. Remove AirPods mid-reply; verify output pauses rather than switching to the speaker; reconnect them and verify the reply resumes.
10. Review Home/server logs for no duplicate submission or replay after interruption, timeout, or reconnect.

Physical-device verification and App Store Review notes for Guideline 2.5.4 remain open release gates.

## Follow-up: reply teardown during iOS background transition

### Incident evidence (reported, CDT)

- An output-capable `AVAudioEngine` started at 20:24:05.226. The app entered background at 20:24:11.736 and logged suspension at 20:24:11.738.
- The device log reported `AVAudioSession` deactivation (`Source: App`) at 20:24:11.746, before engine stop/pause at 20:24:11.755. A RemoteIO interruption followed at 20:24:12.515; the RunningBoard MediaPlayback assertion was invalidated at 20:24:17.514. `UIBackgroundModes` includes `audio`.
- These events establish the sequence, not the initiating code path or whether audio samples played. No incident-linked Home audio events or server turn records establish whether PCM reached the device, playback completed, or Home aborted the response; this report makes no claim either way.

### Source assessment (cause unconfirmed)

- Before this fix, `ContentView.onDisappear` always submitted `.windowDisappeared`. The lifecycle coordinator routes that event to full `deactivate()`, which stops voice work and closes the Home client even when iOS background retention would otherwise keep an active reply. This is a source-level teardown bypass consistent with an app-originated session deactivation, but there is no trace confirming that `onDisappear` ran in the incident.
- Source review found no normal path where `responseTask` clears while scheduled reply buffers remain outstanding: the response awaits output finish, and `AppleAudioOutput.finish()` waits for `AudioPlaybackDrain`. Retention can still become `.none` after playback drains while an engine/session lease remains open. The incident-time retention state is unknown, so that path is not ruled out.
- The audio-category policy was intentionally left unchanged. Category switching remains a secondary, unconfirmed event; the reported `Source: App` record is a session deactivation, not evidence that a category change caused it.

### Fix and verification

- `ContentView.onDisappear` now supplies whether `scenePhase == .active` to the lifecycle coordinator. On iOS, inactive/background disappearance returns without enqueueing `.windowDisappeared`, so it cannot supersede phase work; `.inactive`/`.background` callbacks own that policy. Active-scene window closure still tears down, and macOS/retention-disabled behavior remains unconditional.
- Regression coverage includes `.background` followed by disappearance while a Home reply is playing, `.inactive` → disappearance → `.background` with a playing reply, active-scene close teardown, retention-disabled unconditional teardown, and idle background teardown.
- **Serialized macOS XCTest:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bg-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO` — passed, 615 tests, 0 failures.
- **Signed generic iOS device build:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild build -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS' -derivedDataPath /tmp/ios-bg-device-dd CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES` — passed with the existing Apple Development identity and local provisioning profile. No install, launch, or Home traffic occurred.
- A physical-device retest is required to determine whether this source-level fix changes observed playback; this fix alone does not establish whether playback or server-side turn completion previously failed.

### Approved install-only retest handoff

- Amanda approved an in-place install. Preflight confirmed branch `fix/ios-home-foreground-reconnect`, HEAD `aabb275854af55f16961ee797609ce65d54a6374`, and a clean source tree.
- The exact signed artifact was `/tmp/ios-bg-device-dd/Build/Products/Debug-iphoneos/Hermes Relay.app`. Its executable timestamp was 2026-10-04 21:28:36 CDT; the changed source files were last modified by 21:26:50 CDT. `Info.plist` reports bundle `com.achappell.HermesRelay`, version `0.6.0`, build `1`. `codesign` reports team `37CAHGRH45`. The source was committed as `aabb275` at 21:30:02 CDT, after the build; no code changes occurred between artifact creation and commit.
- The connected target was the paired iPhone 17 Pro Max. Before install, `devicectl device info apps` reported the existing developer app as `com.achappell.HermesRelay`, version `0.6.0` (build `1`), with an accessible data container. The prior install-only handoff records that installed build under team `37CAHGRH45`, matching the artifact’s signing team.
- `devicectl device install app` with the exact artifact above succeeded for bundle `com.achappell.HermesRelay`.
- A post-install metadata-only `devicectl device info apps --bundle-id com.achappell.HermesRelay --require-container-access --include-container-paths` check reported version `0.6.0` (build `1`), `builtByDeveloper=true`, and `containerAccessible=true`. App data was not inspected or copied.
- The app was not launched or opened; no Home requests or household traffic were generated. No tests or rebuilds were run for this install-only handoff; the prior serialized macOS suite passed with 615 tests and 0 failures, and the signed generic iOS build passed. The app awaits Amanda’s physical retest.

## Follow-up: background reply stays "speaking" with no sound (2026-10-05)

- **Report:** Amanda backgrounded Hermes (no app switch) after reply audio had started. Audio stopped; on return the UI still showed speaking with no sound.
- **Evidence:** the device journal copied at 13:25Z does not contain this run, and the journal had no audio events. Proxy/Standard logs do not cover it. No unified log was captured.
- **Inferred cause (not device-confirmed):** `enterBackground` re-applies the live session category as non-mixable (`AppleAudioSessionCoordinator.setBackgroundVoiceActive`). [INFERENCE] That I/O reconfiguration stops the output `AVAudioEngine`. `AppleAudioOutput` never observed `AVAudioEngineConfigurationChange`. Scheduled buffers therefore never played back, `finish()` waited on the drain indefinitely, `responseTask` stayed set, and the state stayed `.speaking`. No resume path runs because nothing paused.
- **Fix:** `AppleAudioOutput` observes its engine's configuration change. While accepting or playing and not paused, it re-activates output, restarts the engine and continues the player. If the restart fails, it uses the existing failure path, so the pending `finish()` throws `outputFailed` and the reply ends as a playback failure. The ducking/non-mixable policy is unchanged. A content-free journal line records `audio output engine stopped restart=ok|failed`.
- **Regressions:** `AudioOutputTests.testEngineConfigurationChangeRestartsStoppedPlayback`, `AudioOutputTests.testFailedEngineRestartFailsThePendingFinishInsteadOfHanging`, and `VoiceSessionCoordinatorTests.testBackgroundOutputEngineFailureEndsTheReplyInsteadOfStayingSpeaking`.
- **Device check needed:** while a reply is audibly speaking, background Hermes. Audio should continue. The next journal copy should show `audio output engine stopped restart=ok`; if it shows `restart=failed`, the reply should end as a failure rather than stuck speaking. The unified log should show the engine configuration change or stop at backgrounding. If neither line appears and audio still stops, this inference is wrong.
- **Automated gates:** `xcodebuild build-for-testing` then `test-without-building` on `platform=macOS` for `AudioOutputTests`, `VoiceSessionCoordinatorTests`, and `AppleLifecycleTests`: 133 tests, 0 failures. iOS Simulator build passed. Both used a temp `HERMES_BUILD_NUMBER_DIR`.

## Follow-up: background during speech stops audio and closes the Home socket (2026-10-05, device-evidenced)

### Evidence (device journal + unified log archive + Home diagnostics; UTC, phone logs were CDT)

Build `0.6.0` with the engine restart fix (`a776a6d`) was installed. Foreground long-thinking turns now deliver audio past the first sentence. Backgrounding during speech still failed, in two runs (A: 17:40:36Z, short reply; B: 17:43:38Z, 31 s into a long reply whose audio started 17:42:56Z).

| Step | Run A | Run B |
|---|---|---|
| App `inactive` → `background` | 17:40:36.36 → 36.96 | 17:43:38.03 → 38.66 |
| New engine/`AURemoteIO` associates with the session | 17:40:37.27 | 17:43:38.97 |
| `AURemoteIO: Session interrupted, will stop iounit` on the playback engine | 17:40:37.82 (+0.55 s) | 17:43:39.50 (+0.53 s) |
| Playback engine paused ("iounit stopped unexpectedly") | 17:40:38.14 | 17:43:39.51 |
| App-side session deactivation | 17:40:38.42 | 17:43:39.74 |
| Home websocket cancelled (TCP FIN from the app first, peer's close frame + `close_notify` = 50 bytes after) | 17:40:39.62 (24 s old) | 17:43:39.76 (80 s old, 101 upgrade) |
| Engine configuration-change notification | 17:40:39.72 | 17:43:40.56 |
| Journal `audio output engine stopped restart=ok` | ×3 (17:40:40.2, :40.9, :41.6) + 17:40:46.6 | ×2 (17:43:40.7, :41.8) |
| `inactive` → `active`, then `open … reconnect_required`, `reconnect … unresolved_turn=false` | 17:40:42.7 / 43.04 → 43.1 | 17:43:40.7 / 41.0 → 41.1 |

- No `AVAudioSessionInterruptionNotification` was posted in either window, so `VoiceSessionCoordinator.handleAudioSessionEvent` never ran. The only audio-session errors were two `SessionCore.mm:717 Failed to set properties, error: '!int'` (`AVAudioSessionErrorCodeCannotInterruptOthers`, 560557684) while restarting the engine in the background in run A. No `!pri`, `-50`, `561015905`, RunningBoard termination/suspension, or background-task expiry; the process stayed `running-active-NotVisible`.
- Home's diagnostics for run B: audio `started` 17:42:56Z, text turn `completed` 17:43:05Z, **no audio `completed`/`failed` event**; the next prompts failed `transport_unavailable` (17:43:57Z) and `hermes_unavailable` (17:44:03Z, 17:44:12Z) until a fresh claim. Home did not stop sending; the app closed the socket under a stream that was still playing. Run A's Home audio (2.3 s) had already completed at 17:40:37.10Z.
- `UIBackgroundModes = [audio]` is in both Info.plist sources and in the built Debug device app (`CFBundleVersion` 16 in DerivedData; `devicectl` reported 15 for the installed bundle, whose own plist could not be read).

### What the code establishes

- `enterBackground` called `AppleAudioSessionCoordinator.setBackgroundVoiceActive(true)`, which re-applied `setCategory(.playAndRecord, …)` on the live, playing session without `duckOthers`. `duckOthers` implies `mixWithOthers` (documented on `AVAudioSessionCategoryOptionDuckOthers`), so removing it turned the active session from mixable to non-mixable. The new engine/`AURemoteIO` association in the log lands right after the background snapshot (~0.3 s after `.background`), 0.53 s and 0.55 s before the interruption in both runs. This is the documented, correlated cause of the stopped playback engine.
- `AppleAudioOutput.handleEngineConfigurationChange` then called `activateOutput()` (`setCategory` + `setActive`). Every re-applied category posts another route change and engine configuration change, which is why run A restarted three times and run B twice. `restart=ok` shows the restart ran and `engine.start()` did not throw; it does not show audible playback.
- The only lifecycle call that closes the Home socket is `AppleLifecycleCoordinator.deactivate()` (`.background` without retention, `.backgroundWorkEnded` from `VoiceSessionCoordinator.evaluateBackgroundRetention`, `.inactive` after retention ended, `.suspended`, `.windowDisappeared` while active). The other closers are `ConversationStore.markHomeSubmissionUncertain` (control/audio deadlines) and open/reconnect retirement in `HomeBridgeSessionClient`. The socket was cancelled by the app (not by a peer close frame first) within 1–3 s of `.background`.

### What remains inferred

- **Which of those closers ran 1–3 s after `.background`** is not provable from the OS log: the app's own info-level logs are not persisted, `deactivate()` was silent, and the output engine was demonstrably not stopped by `output.stop()` (the restart handler still ran afterwards, so the observer and `audioFormat` were intact). It is therefore not established that this closure is a consequence of the interrupted engine; it may be an independent path that the new journal lines will name.
- That removing the session reconfiguration prevents the engine interruption is inferred from the 0.53/0.55 s correlation in two runs, not from a controlled A/B.
- Whether queued player-node buffers play audibly after an engine stop/restart is not visible in logs.

### Fix (this change)

- `AppleAudioSessionCoordinator` now drives `AVAudioSession` through an injectable `AudioSessionDriver` and never reconfigures a live session. `setBackgroundVoiceActive` only records the wanted mixing; it is applied when the session next activates (a new stream/capture after a deactivation). A reply already playing when the app backgrounds therefore keeps its ducking category (and is not eligible for the lock-screen Now Playing card); replies and captures that start in the background are non-mixable as before. Foreground behavior is unchanged.
- Activating a live session with an unchanged category and mode no longer calls `setCategory`. A mode switch on a live session still applies, but keeps the live mixing so it cannot flip the session to non-mixable.
- `AppleAudioOutput` restarts the engine through `reactivateOutput()` (`setActive(true)` only on a live session, no `setCategory`), coalesces a burst of configuration-change notifications into one restart pass (re-checked, at most three passes), and still journals `restart=ok|failed`. `resume()` uses the same re-activation.
- Content-free journal lines (all new) so the next device journal names the closer: `voice background enter retention=…`, `voice background retention ended reason=workFinished|interruption|nowPlayingStop|idleTimeout`, `voice background exit`, `voice audio session event …`, `voice stopForLifecycle …`, `lifecycle input=… active=… retaining=…` (and `superseded`), `lifecycle deactivate trigger=… reply=…`, `lifecycle closing Home client trigger=…`, `lifecycle windowDisappeared scene_active=… ignored|teardown`, `home client close …`, `home client retire socket for reconnect`, `websocket cancel initiator=close|send-task-cancelled`, `websocket closed by peer code=…`, `websocket task completed error=…`, `store Home submission marked uncertain; closing Home client …`, `store Home deadline expired kind=…`, `store Home transport lost unexpectedly; reconnecting`, `audio session category applied mode=… mixing=… live=…`, `audio session mixing wanted=… deferred|applied-at-next-activation`, `audio session interruption began|ended …`, `audio session route change reason=<code>`, and `audio output engine configuration change notification`.

No attempt was made to change retention or teardown rules: with nothing in flight the lifecycle still tears down exactly as before, and the existing background tests for idle teardown, interruption that cannot resume, lock-screen Stop and route loss are unchanged and pass.

### Regression coverage

- `AudioOutputTests`: `testBackgroundNeverReconfiguresALiveSession`, `testDeferredNonMixableRuleAppliesWhenTheSessionNextActivates`, `testAnIdleSessionTakesTheBackgroundRuleAtActivation`, `testALiveSessionKeepsItsMixingWhenTheModeSwitches`, `testReactivatingALiveOutputSessionOnlyActivatesIt`, `testEngineRestartReactivatesTheSessionWithoutReapplyingItsCategory`, `testBurstOfConfigurationChangesRestartsTheEngineOnce`.
- `VoiceSessionCoordinatorTests`: `testBackgroundedPlayingReplyKeepsTheSocketAndExplainsTeardownInTheJournal` (`.inactive` → `.background` with a live response keeps the socket, retention and journals `retention ended reason=workFinished` only after the reply ends), `testJournalNamesTheInterruptionThatEndedBackgroundRetention`, `testJournalNamesTheLockScreenStopThatEndedBackgroundRetention`, `testJournalNamesWindowDisappearanceAndIdleBackgroundTeardown`.
- **macOS XCTest (serialized):** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bgfix-dd CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=37CAHGRH45 HERMES_BUILD_NUMBER_DIR=<temp dir> -parallel-testing-enabled NO`: 629 tests (618 at `a776a6d` + 11 new). Focused `AudioOutputTests` 30, `VoiceSessionCoordinatorTests` 109, `AppleLifecycleTests` 5: 0 failures. Across 11 full-suite runs, 7 were clean; the other 4 failed only `VoiceSessionCoordinatorTests.testBackgroundOutputEngineFailureEndsTheReplyInsteadOfStayingSpeaking` ("Expected a playback failure, got idle": retention ends and teardown can run before the test's `.active`) and/or the known flaky `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery`. The baseline at `a776a6d` (a temporary worktree, 8 full runs) also failed 2 of 8 runs, one of them inside `VoiceSessionCoordinatorTests`, so the flakiness predates this change; the failing test names of the other baseline run were not captured.
- **iOS Simulator build:** `xcodebuild build -destination 'generic/platform=iOS Simulator'` with the same signing/build-number overrides: succeeded. Not installed on a device; no Home traffic.

### Device check for Amanda (next build)

1. Install the new build, open Hermes, submit a prompt that takes 30+ seconds so audio plays for a while, and background it (swipe home) 10+ seconds into the audio. Leave it backgrounded for at least the rest of the reply, then return.
2. Expected: audio keeps playing from the lock/home screen without a gap; on return the transcript shows the full reply and the UI is not stuck "speaking".
3. Share diagnostics (Settings → Share) and look at lines after the background time. Healthy: `voice background enter retention=reply`, `audio session mixing wanted=nonMixable deferred live=true`, **no** `audio session category applied … live=true` and **no** `audio output engine configuration change notification` or `restart=` at backgrounding, `voice background exit` on return, and no `lifecycle deactivate`/`home client close`/`websocket cancel` before the reply ends.
4. If it still fails, the journal now names the closer. Read the lines between `app phase=background` and the first `home connect open result=unavailable reconnect_required`: the line immediately before `home client close` or `websocket cancel initiator=…` is the initiator (`lifecycle deactivate trigger=…`, `store Home submission marked uncertain …`, `store Home deadline expired kind=…`, or `home client retire socket for reconnect`); `websocket closed by peer code=…` would instead mean Home closed it.

## Follow-up: build 17 retest — lifecycle bound to an orphaned voice coordinator (2026-10-05)

### Evidence (in-app diagnostics export, build `0.6.0` (17), UTC)

- 19:13:47.5 `prompt.submit`; Home audio started 19:13:59.06 (category `spokenAudio` applied 19:13:58.99); Home text turn completed 19:14:00.6; **no** Home audio completed/failed row.
- 19:14:05.75 `inactive`; 19:14:06.41 `background`; 19:14:06.639 `lifecycle deactivate trigger=backgroundWithoutRetention reply=none`; 19:14:06.644 `voice stopForLifecycle reply=false hands_free=false backgrounded=false`; a 3.35 s journal gap; 19:14:09.999 `lifecycle closing Home client`, `home client close socket=true turn_audio=true`, `websocket cancel initiator=close`, then the peer's close-frame echo.
- 19:14:10.11 / .24 `audio output engine configuration change notification` / `restart=ok`: the playback engine's observer and stream were still alive after "teardown" had finished. There was no `voice background enter` or `audio session mixing wanted=` line, so `enterBackground` never ran.
- The unified log archive could not be captured (libimobiledevice could not see the phone), so the RunningBoard/AURemoteIO view of this run is missing.

### Root cause (code-established; device confirmation pending)

`ContentView.init` built the whole voice stack (`AudioActivityStore`, `AppleAudioSessionCoordinator`, `AppleSpeechInput`, `AppleAudioOutput`, `VoiceSessionCoordinator`) and the `AppleLifecycleCoordinator` on every call. SwiftUI re-runs that initializer whenever `HermesRelayApp.body` re-evaluates — every scene phase change does, because the App body reads `scenePhase`. `@State` keeps only the first `VoiceSessionCoordinator`; `lifecycleCoordinator` was a plain `let`, so the `.onChange(of: scenePhase)` handler used a lifecycle coordinator bound to the newest, never-used voice coordinator. That orphan has no response task, so `backgroundRetention` was always `.none`, and `deactivate()` ran against shared objects:

- `store.takeHomeClientForLifecycle()` + `close()` closed the real Home socket (shared `ConversationStore`), which is the observed `home client close … turn_audio=true`.
- `orphanVoice.stopForLifecycle()` stopped the orphan's own output and speech engines, not the real ones: the real output kept its observer and stream, which is why `restart=ok` still ran after "teardown". It also explains the 3.35 s stall (the orphan `AppleSpeechInput.cancel()` touches `AVAudioEngine.inputNode` in the background).
- The orphan's `AppleAudioSessionCoordinator` thinks it holds no session, so its `deactivateOutput()`/`deactivateInput()` call `AVAudioSession.setActive(false)` on the shared system session under the real playback ("Deactivated session … Source: App").
- A new engine/`AURemoteIO` associating with the session ~0.3 s after `.background` in the 17:40/17:43 old-build runs matches the orphan's speech engine creating its input node, not `setBackgroundVoiceActive`'s `setCategory` (which was never reached). The "Session interrupted, will stop iounit" 0.5 s later is therefore attributable to the orphan teardown, not to the category re-apply.

The hypothesis that the voice response task clears when Home's control turn completes while audio still streams is **not** what happened: `ConversationStore.sendTurn` waits for the Home audio terminal before returning, the coordinator's `.audioEnd` handling awaits the playback drain before the response ends, and `testControlTurnCompletingWhileAudioStreamsKeepsReplyRetentionAndTheSocket` passed unmodified against the existing code (retention `.reply`, socket open, teardown only after terminal + drain). No belt-and-braces "audio stream active" retention predicate was added: with a correctly bound coordinator the response task already spans the stream, and a second predicate could wedge retention if a stream flag were left set.

### Fix

- `ContentViewRuntime` builds the activity store, voice coordinator and lifecycle coordinator once; `ContentViewRuntimeBox` (held in `@State`) hands the same instance to every re-initialised `ContentView`. `voiceCoordinator`, `activityStore` and `lifecycleCoordinator` are now computed from it, so the phase handlers and the UI act on the same objects. Behavior with nothing in flight is unchanged (background still deactivates); with a reply in flight the designed IOS-HOME-07 retention now actually runs on device for the first time.
- Journal: `runtime created` (must appear once per launch), `voice response started path=voice`, `voice response ended path=voice|draft|resend state=… audio_stream=… paused=… backgrounded=…`, `store Home sendTurn returning completed=… audio_terminal=… audio_requested=…`.

### Fix B re-examined

The deferral of mixing changes on a live session stays: it is harmless for background playback (a mixable `playAndRecord` session with `UIBackgroundModes=audio` keeps playing; `duckOthers` implies `mixWithOthers` per the SDK header) and avoids reconfiguring running I/O. The only cost is that a reply already playing at background time is mixable and is not eligible for the lock-screen Now Playing card; replies/captures that activate while backgrounded are non-mixable. The earlier correlation between `setBackgroundVoiceActive` and the interruption is retracted (see above): it is unproven. If the retest shows `Session interrupted` after a real `voice background enter`, switch to activating the Home reply session non-mixable up front.

### Regression coverage

- `VoiceSessionCoordinatorTests`: `testControlTurnCompletingWhileAudioStreamsKeepsReplyRetentionAndTheSocket`, `testViewReinitialisationReusesOneRuntimeBoundToTheVoiceCoordinatorInUse` (one runtime across repeated `resolve`, lifecycle bound to the voice in use), `testRuntimeLifecycleKeepsAReplyWhoseControlTurnCompletedBeforeItsAudioEnded` (background via the runtime's lifecycle keeps `retention=reply`, socket open, no `deactivate`; retention ends after audio terminal + drain), `testRuntimeLifecycleStillTearsDownWhenNothingIsInFlight`. SwiftUI re-initialisation itself is not unit-testable here; the seam is the runtime box.
- **macOS XCTest (serialized):** 633 tests (629 + 4 new). Focused `VoiceSessionCoordinatorTests` 113, `AudioOutputTests` 30, `AppleLifecycleTests` 5: 0 failures. Six full-suite runs: 3 clean; the others failed only the known-flaky `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery` (2 runs) and `VoiceSessionCoordinatorTests.testBackgroundOutputEngineFailureEndsTheReplyInsteadOfStayingSpeaking` (1 run; retention-end teardown can run before the test's `.active`). Both also flake on the pre-change baseline `a776a6d`.
- **iOS Simulator build:** succeeded. Not installed; no Home traffic.

### Device check for Amanda (next build)

1. Install the build and launch it once, then do the 30+ s prompt and background ~10 s into the audio; stay backgrounded through the end of the reply.
2. Expected journal after `app phase=background`: `voice background enter retention=reply`, `audio session mixing wanted=nonMixable deferred live=true`, no `lifecycle deactivate`/`home client close`/`websocket cancel` until the reply ends, then `voice response ended path=voice state=complete audio_stream=false …`, `voice background retention ended reason=workFinished`, `lifecycle deactivate trigger=backgroundWorkEnded reply=none`, and `home client close`. `runtime created` appears exactly once per launch (none means the build predates this fix; two or more means the stack is still being re-created).
3. If it still tears down at `.background`, the `lifecycle input=background … retaining=` and `voice response ended` lines say whether the response task ended first and in what state.

## Follow-up: stutter at background entry on build 18 (2026-10-05)

### Evidence

- Build 18 (`0.6.0` (18), the 8482051 stack) kept the reply playing after `.background`; the user hears a transient stutter ("eh-eh-eh-eh-eh") for about two seconds **every** time she backgrounds during playback, and none on the return to the foreground.
- Journal for the run (UTC): reply audio started 20:50:13.2 (`category applied mode=spokenAudio mixing=duckOthers live=false`), `inactive` 20:50:17.63, `background` 20:50:18.27, `voice background enter retention=reply` and `audio session mixing wanted=nonMixable deferred live=true` at 20:50:18.497. Then **no journal line for 50 s** until she returned (20:51:08.6): no route change, interruption, `audio output engine configuration change notification`, `restart=`, or `category applied`. The engine restart/coalescing path did not run, the mixing deferral made no driver call, and nothing paused the player.
- No unified-log archive could be captured: libimobiledevice does not see the phone (`idevice_id -l/-n` empty) although `devicectl` shows it connected over a CoreDevice local-network tunnel, and `log collect --device-udid` needs root.

### Cause space (ranked, not proven)

1. Main-actor contention at the scene transition meeting a player with no cushion. Every Home PCM chunk takes the main actor (store pump, then coordinator, then the output actor), and Home streams at about real time, so the player started on the first buffer with roughly one chunk of lead. At background entry the app did three things on that same actor: scene work, the `nowPlaying.show` registration (four remote-command targets plus an info write), and then a MediaPlayer info write **per PCM chunk** (`updateNowPlayingPlaybackState` ran on every `.ready` chunk once the card existed). Foreground playback has no card, so those writes were no-ops there, which fits "only at background entry".
2. An OS-side render/IO-buffer change when the app leaves the foreground, hitting the same zero-cushion stream. Unverifiable without a log archive.
3. Engine restart, session, mixing, route or pause/play churn: **ruled out** by the journal for this run.

### Changes

- **Now Playing:** writes only when the playing flag changes and only while a card is registered; the one-time registration (`nowPlaying.show`) is deferred 750 ms after background entry (cancelled if the app returns first, so the card is never registered for a quick peek). `nowplaying_writes=N` (writes since background entry) is added to `voice response ended`.
- **Feed path:** `output.append` runs before the per-chunk `chunkReceived` diagnostic, removing one main-actor round trip before every chunk is scheduled. The lifecycle snapshots and the session-policy call at `.inactive`/`.background` already run as awaits on other actors (persistence and session coordinator); no other synchronous main-actor work remains on that path. Moving PCM hand-off off the main actor entirely (a store-level PCM sink) was judged too invasive for this change; revisit only if the lead journal shows pump latency larger than the cushion.
- **Playback cushion:** `AppleAudioOutput` delays `playerNode.play()` until 300 ms of audio are scheduled (`AudioPlaybackCushion.standard`), starts earlier when the stream ends first (`finish()`), and never holds longer than 500 ms after the first buffer. While held, `append` reports `.buffering` (the UI stays "buffering" instead of "speaking"). Pause keeps it held; resume or an engine restart starts it; stop cancels the timer. Cost: about 300 ms extra start latency on a real-time stream (500 ms at most). Journal: `audio output cushion started lead_ms=N reason=threshold|cap|finish`.
- **Verification journal:** `audio output lead_ms=N t_ms=T state=… playing=…` at background entry and every 250 ms for 5 s (21 lines), where N is the scheduled-but-unrendered audio in milliseconds (`AudioOutput.playbackLead()`).

### Regression coverage

- `AudioOutputTests` (+7): threshold start with `.buffering` while held, short stream starts at `finish()`, hard cap, pause keeps it held and resume starts, stop cancels the timer, `.none` starts on the first buffer, and a sub-cushion stream cannot hang `finish()`.
- `VoiceSessionCoordinatorTests` (+5): 40 same-state chunks after background make no MediaPlayer write (pause/play write once each, `nowplaying_writes=4`), card registration waits the 750 ms beat, never registers if the app returns first, lead lines at t=0…5000 ms then stop, and sampling stops on return. Two existing tests were updated for the new behavior: the lock-screen test no longer sees foreground updates (`[false, true]`), and `testFailedEngineRestart…` filters the journal to the restart lines.
- **macOS XCTest (serialized):** 645 tests (633 + 12). Focused: `VoiceSessionCoordinatorTests` 118, `AppleLifecycleTests` 5, `AudioOutputTests` 37, 0 failures. Across 14 full-suite runs, 9 were clean; the 5 others failed only the two known flaky tests (`ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery`, `VoiceSessionCoordinatorTests.testBackgroundOutputEngineFailureEndsTheReplyInsteadOfStayingSpeaking`), which also fail on the pre-change baseline.
- **iOS Simulator build:** succeeded. Not installed; no Home traffic.

### Reading the new journal lines (retest)

```
voice background enter retention=reply
audio output lead_ms=612 t_ms=0   state=speaking playing=true
audio output lead_ms=601 t_ms=250 state=speaking playing=true
…
audio output lead_ms=588 t_ms=5000 state=speaking playing=true
```

- `audio output cushion started lead_ms=300…340 reason=threshold` appears once at the start of each reply (about 0.3 s after the first chunk).
- `lead_ms` is how much audio is queued ahead of the renderer. Healthy is a roughly constant value near 300 ms or more through the 5 s.
- Lead stays above ~100 ms through the background entry **and you still hear stutter** → the cause is OS render/IO timing, not feed latency; capture a log archive (below).
- Lead drops to ~0 (a few samples at 0–30 ms) around `t_ms` 0–2000 → the feed (main-actor pump or network) starved the player; the cushion was too small for the stall, and the next change is moving PCM hand-off off the main actor.
- `nowplaying_writes=` on `voice response ended` should be small (a handful: the card registration plus pause/play/finish), not hundreds.

### Capturing a real log archive (not available from this machine today)

`idevicesyslog` needs the phone on usbmuxd: plug the phone in with a USB cable, unlock it, tap Trust if asked, then `idevice_id -l` must print the UDID. Repro: start a long reply, background it, return. Then from the Mac: `idevicesyslog archive /tmp/hermes-bg.tar --start-time $(( $(date +%s) - 300 ))`, extract and rename to `.logarchive`, or with admin rights `sudo log collect --device-udid <UDID> --last 5m --output /tmp/hermes-bg.logarchive`. Look for `AURemoteIO`/`AVAudioEngine` start-stop lines, IO buffer duration changes and the `mediaremoted` activity around `app phase=background`.
