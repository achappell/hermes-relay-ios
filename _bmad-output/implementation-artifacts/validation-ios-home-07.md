# IOS-HOME-07 Validation

Date: 2026-10-04
Baseline: `feeb475fc113e88ab0a0e496fe557b6e39c06fbe` (`fix/ios-home-foreground-reconnect`)

## Automated gates

- **macOS XCTest:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ios-bg-dd CODE_SIGNING_ALLOWED=NO` — passed, 591 tests, 0 failures. Includes IOS-HOME-04/05/06 coverage and IOS-HOME-07 lifecycle/voice tests.
- **iOS Simulator build:** `DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild build -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ios-bg-dd-ios CODE_SIGNING_ALLOWED=NO` — passed. No iOS Simulator runtime is installed; no iOS tests were run.
- **Test-first baseline check:** copied the new voice/output test files into a detached worktree at `feeb475` and ran `xcodebuild build-for-testing`. It failed as expected because the new APIs/types (`NowPlayingPresenting`, `BackgroundAudioSessionPolicy`, `AudioSessionEventSource`, `AudioOutput.pause/resume`, `AudioSessionMixing`) do not exist on baseline. This confirms the tests are red against baseline at compile time, not that an existing behavior assertion ran and failed.
- **Pre-existing flaky baseline test:** `ConversationStoreReconnectTests.testAutomaticHomeReconnectCanReleaseConfirmedInactiveRecovery` failed in 2 of 4 isolated baseline runs before that loop was stopped; both failed assertions showed `reconnecting(attempt: 1, of: 5)` instead of connected. The full final suite passed.

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