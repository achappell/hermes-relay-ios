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
