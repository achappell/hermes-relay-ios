# IOS-HOME-08 validation

## Scope

Shared iOS/macOS Home interruption after control completion: preserve known terminal truth, stop server audio when necessary, settle local buffered playback, and keep stale acknowledgement/drain work from changing a newer turn. No decoder or unrelated UI change.

Baseline: `422a54731c3cae2142d350781360dc783e1f3904`. Home contracts inspected at PR83 `b964082c034ea60c249678ce416db7015cb0a382` and PR85 `d803994d1d47c63bb1b3c92cff42695de19a4434`. Home tail acknowledgement follows sidecar admission release, without a second control terminal; recently retired IDs are accepted no-ops. Public audio end remains kind-only.

## Failing-before evidence

Xcode 27.2 beta 2, local macOS arm64, unsigned XCTest, serialized execution. Production source was unchanged.

- `testHomeControlCompletionAfterInterruptAcknowledgementIsPreserved`: failed `isSending` and successful-stop assertions.
- `testHomeControlCompletionBeforeInterruptAcknowledgementIsPreserved`: exceeded its two-second acknowledgement-completion expectation and failed `isSending`. The initial run was cancelled after the red-test cleanup itself blocked; test cleanup was corrected to deactivate lifecycle before disconnecting (disconnect intentionally refuses while sending).
- Completed second run: **3 tests, 2 failed, 1 passed**, result bundle `/tmp/hermes-tail-interrupt-red-ordering.xcresult`.
- `testHomeTailInterruptAcknowledgementNeedsNoSecondControlTerminal`: exceeded its two-second stop-completion expectation.
- `testHomeNativeDrainReleasedByStopCannotOwnTheNextTurn`: reported failed relay-restoration state instead of interrupted.
- Existing `testHomeInterruptWaitsForMatchingTerminal`: passed, preserving the negative requirement that an active turn's acknowledgement is not a terminal.

## Post-fix checks

- Full serialized macOS arm64 build/XCTest: **666 passed, 0 failed, 0 skipped**, `/tmp/hermes-tail-interrupt-macos.xcresult`. Xcode 27.2 beta 2; `xcodebuild test -project 'Hermes Relay.xcodeproj' -scheme HermesRelay -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/hermes-tail-interrupt-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO`.
- The result bundle reports four QoS runtime warnings from existing `AudioOutputTests.swift`; no test failures. This change does not claim to resolve those warnings.
- Full serialized iOS Simulator build/XCTest: **667 passed, 0 failed, 0 skipped**, iPhone 18 Pro Max simulator / iOS 27.2, `/tmp/hermes-tail-interrupt-ios.xcresult`. Used the same scheme with `-destination 'platform=iOS Simulator,id=EA401D8D-F4C7-4EA7-A3D4-A22DB165BB54' -derivedDataPath /tmp/hermes-tail-interrupt-ios-dd`.
- iOS build reports existing missing app-icon size warnings; XCTest reports the same four existing audio-test QoS warnings. Post-test simulator diagnostic collection also reported `simctl` unavailable in its subprocess environment, but the completed xcresult independently reports all 667 tests passed.
- Earlier focused post-fix run: 150 passed, one native-only assertion failed. Investigation found the fixture's audio-end drain blocked control-terminal observation; the fixture ordering was corrected, retaining its no-server-interrupt assertion. The full passing suite includes the corrected case.
- Independent review identified three actionable issues (smoke private access, rejected-stop cleanup ownership, Now Playing stopped-state publication). All were patched and a focused independent re-review found no actionable remainder.
- Final local runtime smoke: **PASS**, exit 0. Command: `export PATH=/opt/homebrew/bin:$PATH; export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer; uv run --no-project --with websockets python scripts/home-tail-interrupt-smoke.py`.
- The smoke compiled current production Models/Services/ViewModels and exercised `ConversationStore` through the real URLSession Home client, decoder, and event pump over loopback TLS. It preserved completed text through a tail stop, waited for a matching active-turn terminal despite acknowledgement/stale terminal, and accepted the next explicit prompts. Peer evidence: one HTTP upgrade/connection/ready reply, exactly three explicit submissions, two interrupts, no replay.
- Smoke fixture corrections also supplied required TLS server-authentication EKU after observed SecTrust error `-67609` and classified connection closure as teardown only after all three turns and exact request counts completed. Exact certificate pinning/trust evaluation remains enabled; client success and all scenario assertions remain required. Final scripts-only independent review found no actionable masking/security defect.
- First loopback smoke compiled but failed before socket open: its synthetic credential used a one-hour lifetime, violating the production 90-day credential contract. The fixture was corrected to a single issue timestamp, expiry at 90 days and renewal at 76 days; no production credential validation was weakened.

## Acceptance boundaries

A local loopback runtime smoke can verify the production Apple store/URLSession Home bridge against a contract peer, not deployed Home or native output hardware. Deterministic coordinator tests cover the native-drain ownership seam. Physical iPhone/iPad/macOS audio, lock-screen, route changes, interruptions, and deployment acceptance are not established by this work. No user-device install, Pixel access, or Home deployment is authorized.

## Release notes

The conventional `fix(ios)` commit supplies Release Please's generated changelog. Existing versioned changelog sections are intentionally not edited.

## Owner acceptance - 2026-10-08

Amanda manually tested IOS-HOME-08 on her own device and accepted it as `done` on 2026-10-08, saying it works well enough to accept.

- No instrumented evidence, steps, or build number were captured by the agent.
- The specific remaining device checks listed in this record were not individually exercised by the agent and remain unverified.
- The earlier evidence and limitations above are unchanged; this section records an owner decision, not a new test run.
