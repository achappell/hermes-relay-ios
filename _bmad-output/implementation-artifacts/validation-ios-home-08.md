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

## Bounded native Mac acceptance — 2026-10-07

Verification only, against source `1eb76923e5cb2486ab42bb0d12b825db91811cd5` in isolated `.worktrees/apple-review-acceptance`. The older installed Mac binary predated HOME08 and was not used as fix evidence. Built the current source with existing repository Debug signing:

```sh
export PATH=/opt/homebrew/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
xcodebuild -quiet -project 'Hermes Relay.xcodeproj' -scheme HermesRelay \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/hermes-apple-review-acceptance-1eb76923 build
```

Build **PASS** (exit 0). Ran the resulting native app directly from that isolated path. Its bundle identifier and Apple Development designated signing requirement matched the original app; no replacement install or signing change occurred. Executable SHA-256: `d44d142dbfb734d1ff29e4622fab2298782cfd8db76fb2cc2d920955436c5b92`. Existing Home configuration reached “Home bridge Ready, Approved route reachable.”

Before using the macOS orb (which stops output and begins capture), read supported authorization getters inside this exact running app with a temporarily attached debugger: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()` both returned authorized (`3`). No permission request/grant occurred; debugger detached before interaction.

Content-free observations, UTC on 2026-10-08:

| Time | Actual observation |
| --- | --- |
| 02:36:55.275 | Initial bounded synthetic typed reply submitted; it finished before a stop was exercised. Not stop acceptance. |
| 02:40:42.167 | Bounded synthetic typed playback-test prompt submitted. |
| 02:40:42.730 | Native orb reported Thinking. |
| 02:41:20.539 | Native orb reported Speaking. |
| 02:41:20.766 | Activated the native voice orb stop/start-listening action. |
| After stop | Orb reported Unavailable, not a stable Listening state. |
| 02:42:20.152 | Next explicit typed prompt submitted; send was enabled. |
| 02:42:20.680–02:42:30.408 | Thinking → Speaking → Complete. |

**PASS, bounded:** the observed stop did not wedge the next explicit typed prompt; native UI reached Speaking and Complete afterward. **Not established:** that stop occurred after both server terminals while only native buffered audio remained; audible quality/completion was not independently observed. This is not a full HOME08 physical acceptance pass, and “immediate next prompt” latency was not measured: inspection intervened before the next submission.

**Capture failure, separate from permission/interrupt:** read-only unified logs in the same narrow window show the native output engine stopping at 02:41:20.806, input engine starting at 02:41:21.146, and the local speech service reporting at 02:41:21.189: `kLSRErrorDomain Code=201`, “Siri and Dictation are disabled.” The app's speech XPC connection invalidated at 02:41:21.192 and input engine stopped at 02:41:21.208. [INFERENCE] The Unavailable state arose during speech-capture startup following interruption, rather than from denied app permissions. The exact app error value was not captured; no claim is made that Home audio-end or interrupt failed, or that this is an Android defect.

Read-only Home operational-log corroboration found two accepted submissions at 02:40:42.633 and 02:42:20.605 with response-write-returned records. These are timestamp-window observations, not an exact correlation-ID join or client receipt proof. That stream exposes no explicit interrupt, control-terminal or audio-end record. Socket finalization after quitting reported locally observed status 1006; this is not a received wire close code or a diagnosed failure cause. No private IDs or conversation content are retained here.

Cleanup: final UI state Complete/Starts listening, then quit the isolated app; process absence confirmed. No active test capture/driver remains. Original app, settings, credentials and existing data were preserved; only the authorized synthetic conversation turns were added. No opt-in changes, unpairing, grants, device install, Home deployment or physical iPhone/iPad/Pixel use. No tests or CI watches were rerun.

### Remaining Apple batch gates

All seven tracker entries intentionally remain `review`. Earlier automated evidence remains as recorded in each owning validation artifact; the following are this batch's results, not replacements for prior passes:

| Story | This batch | Remaining exact acceptance boundary |
| --- | --- | --- |
| IOS-HOME-04 | Not run | Physical iPhone >120 s background/foreground, automatic Ready/fresh claim without replay. |
| IOS-HOME-05 | Not run | Physical iOS/live Home slow text followed by audio; deadline behavior under current HOME07 rules. |
| IOS-HOME-06 | Not run | Physical iPhone long background return, truthful disconnected/Ready state and usable talk without manual Connect. |
| IOS-HOME-07 | Not run | Owning validation's physical background/mic/Now Playing/interruption/route checks and App Review notes; no macOS substitute. |
| IOS-HOME-08 | Partial pass; capture unavailable | Next typed prompt completed after native stop. Exact terminal/native-tail boundary and full physical acceptance remain unverified. |
| IOS-DIAG-02 | Not run | Existing-consent physical failure/relaunch/durable-upload journey and signed-in Home receipt; no automatic upload was enabled. |
| IOS-DIAG-03 | Not run | Exact connection/request/correlation mapping after socket finalization, `/pair` presentation and legacy-device checks. |

No story is closed and no cross-platform waiver is applied.

## Owner acceptance - 2026-10-08

Amanda manually tested IOS-HOME-08 on her own device and accepted it as `done` on 2026-10-08, saying it works well enough to accept.

- No instrumented evidence, steps, or build number were captured by the agent.
- The specific remaining device checks listed in this record were not individually exercised by the agent and remain unverified.
- The earlier evidence and limitations above are unchanged; this section records an owner decision, not a new test run.
