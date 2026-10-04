---
story: IOS-HOME-05
spec: spec-ios-home-05-audio-start-after-turn.md
home_contract: hermes-relay-home 082e593 (HOME-NW-18)
status: local-verified-live-gates-open
updated: 2026-10-04
---

# IOS-HOME-05 validation record

Defect: on iOS main 66477da, slow Home text generation outlasted the 5 s audio-start deadline, and the app reported playback failure before Home sent its response audio.

| Gate | Status | Evidence |
| --- | --- | --- |
| Regression fails before fix | Confirmed | `testHomeSlowTextReplyStillPlaysAudioThatStartsAfterTheTurnCompletes` failed: coordinator entered playback-failure state and no audio chunk was appended. |
| Regression: slow text, then audio | Passed | Audio-start timer now begins only after successful turn completion; subsequent audio reached output. |
| Regression: no audio after text completion | Passed | Failure occurred after the configured 200 ms post-completion audio-start deadline; no audio was appended. |
| Full macOS XCTest | Passed | 567 tests, 0 failures. Result bundle: `/tmp/ios-audio-dd/Logs/Test/Test-HermesRelay-2026.10.04_13-32-32--0500.xcresult`. |
| Generic iOS Simulator build | Passed (compile only) | `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-audio-dd-sim build` succeeded. `xcrun simctl list runtimes` lists no installed runtimes, so no simulator tests ran. |
| Physical iOS / live Home | Not run | No household requests or TTS calls. |
| Merge / release | Not performed | Local commits only; no push or PR. |

The regression tests were first run against the original implementation: the slow-text test failed as expected, showing the playback-failure state before audio delivery. Both tests pass with the fix.
