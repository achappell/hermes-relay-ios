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


## Device-only checks for Amanda

On a physical iPhone, Release build:

1. Lock the screen during a generated reply; verify the entire reply plays, then Home disconnects/parks the claim.
2. Open Control Center during playback and during hands-free capture; verify `.inactive` alone does not stop either.
3. With hands-free armed in the foreground, lock the phone and speak a follow-up within 60 seconds; verify the new turn is submitted exactly once.
4. Leave hands-free idle in the background for 60 seconds; verify capture stops and the orange microphone indicator clears.
5. Use lock-screen Now Playing Pause/Play and Stop; verify Pause/Play control output, Stop ends the session and clears the card.
6. Play a podcast, then start background voice work; verify the podcast is interrupted and resumes after Hermes releases the session.
7. Take a phone call during reply playback; verify mic session ends and unfinished reply resumes only when the interruption ends with `.shouldResume` and transport/timeout conditions still hold.
8. Remove AirPods mid-reply; verify output pauses rather than switching to the speaker; reconnect them and verify the reply resumes.
9. Review Home/server logs for no duplicate submission or replay after interruption, timeout, or reconnect.

Physical-device verification and App Store Review notes for Guideline 2.5.4 remain open release gates.