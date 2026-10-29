# IOS-STD-01 validation

## Scope and baselines — 2026-10-29

Required typed Slice 1: explicit direct Standard setup on iOS/macOS, typed streaming, private identity-scoped history, durable recovery without replay, and honest connection/conversation controls. Optional direct voice is unavailable, not simulated. HomeBridge and existing Legacy profiles remain supported and separate.

Apple implementation starts at `4c48f11`. The actual unmodified upstream native interface was exercised from an isolated clean checkout of `83bde48a4d9760d84220a9b29094a1ad86410f6e`, using Python 3.14.9. This does not depend on the pending upstream audio contribution. No production Hermes configuration, endpoint, model, token or household-patched source was used.

The runtime fixture starts the real upstream gateway/session authority and `AIAgent`, with a private temporary home and a synthetic OpenAI-compatible loopback model. TLS forwarding changes only the transport to WSS; it does not replace the upstream protocol handlers. Network auditing restricts the fixture to loopback.

## Verified native contract

- `/api/ws` rejects missing/wrong query tokens and bearer-header-only authentication with HTTP 403. A valid native query token succeeds. The authenticated URL exists only inside the Apple transport, never saved as the endpoint or surfaced in errors.
- `gateway.ready` must advertise `session_authority: true`. `gateway.ping` is authenticated, non-creating readiness. Older/noncanonical interfaces are unsupported; there is no Legacy or Home fallback.
- Canonical create uses the Hermes target `profile`; the old `source` parameter is rejected. The server returns both runtime and durable session references.
- Deliberate `prompt.submit` carries a unique submission ID. Queued acknowledgements can precede execution generation assignment; admission/generation-correlated events stream text through `message.complete`.
- Canonical durable `session.resume` with `omit_messages: true` performs no model work or prompt replay. A later deliberate prompt performs new work.
- A generation-scoped interrupt acknowledgement can still report `execution_state: running`. The actual matching terminal subsequently reports cancelled/interrupted; acknowledgement alone is not treated as cancellation proof.

## Runtime and native surface evidence

- **PASS: production macOS store-to-agent smoke.** Compiled the current production Models/Services/ViewModels and exercised `ConversationStore`, `StandardSessionClient`, real URLSession WebSockets and JSON persistence against the clean upstream agent. Typed text streamed; a recreated store resumed the durable reference without increasing model request count; the next deliberate prompt increased it exactly once. A new local connection identity loaded no previous transcript. Direct voice remained unavailable. Credentials in this driver were memory-only; its certificate pin applied only to the synthetic loopback session.
- **PASS: actual iOS Simulator UI flow.** A temporary native UI runner drove the normally built app: explicit HomeBridge/Standard choice, Standard endpoint/secure token fields, authenticated check/save through the real simulator Keychain, explicit New, typed send and visible synthetic reply, Leave, and deliberate return to setup choices. Home-only conversation controls were absent. Final screenshot review also caught a voice preference visible during Add profile while Standard remained selected; the existing mode guard now hides it. After that UI-only adjustment, both platforms rebuilt and the complete native flow passed again with an explicit absent-toggle assertion. The fixture used only the dedicated test simulator and synthetic token.
- **PASS: actual macOS setup UI.** Launched the compiled app with an isolated verification bundle identifier and existing sandbox entitlements, ad-hoc signed only the temporary derived app. Native accessibility actions opened setup and selected Standard; endpoint, secure token, optional target and save controls appeared. Home automatic diagnostics settings were absent. The actual window was captured and visually inspected. No Mac Keychain credential, global trust setting, microphone grant or production connection was needed for this bounded setup check.
- **Failing-before/passing-after native teardown proof.** Initial Mac Standard selection remained disabled. A process sample traced the setup task through `stopForLifecycle` → `AppleSpeechInput.cancel` → `stopResources` → `AVAudioEngine.inputNode`, blocked in Core Audio while cancelling an idle input. Teardown now caches/removes only an actually installed input tap. The rebuilt native Mac app completed the same setup action and displayed the direct form without initializing idle microphone hardware. Active-capture coordinator regression coverage remains in the full suite.

Native screenshots were inspected from local temporary evidence, not committed as application assets. UI automation/drivers, synthetic homes and TLS material are verification scaffolding, not shipped code.

## Build and XCTest evidence

Xcode 27.0 (`27A266a`), macOS 27.0.1 arm64; dedicated iPhone 18 Pro / iOS 27.0 simulator. Global `xcode-select` was not changed.

| Check | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Full isolated serialized iOS Simulator build/XCTest | 791 | 0 | 0 |
| Full isolated serialized macOS arm64 build/XCTest | 790 | 0 | 0 |

Final full-suite result bundles: `ios-final-isolated-serial.xcresult`, `mac-final-isolated-serial.xcresult`; final rebuilt simulator UI receipt: `ui-final-mode-isolation.xcresult`, one passed scenario with inspected native screenshots. These are within the task's temporary `hermes-apple-direct-*` run directory. The owning spec/index/tracker also passed a system-YAML-parser consistency check: unique story identity, existing evidence links, `review` story status and Epic 2 `in-progress`.

Commands use `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer`:

```sh
xcodebuild -quiet -project 'Hermes Relay.xcodeproj' -scheme HermesRelay \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -jobs 4 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  -derivedDataPath "$RUN/ios-build" \
  -resultBundlePath "$RUN/ios-final-isolated-serial.xcresult" test

xcodebuild -quiet -project 'Hermes Relay.xcodeproj' -scheme HermesRelay \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 4 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  PRODUCT_BUNDLE_IDENTIFIER=com.achappell.HermesRelay.StandardVerification \
  -derivedDataPath "$RUN/mac-build" \
  -resultBundlePath "$RUN/mac-final-isolated-serial.xcresult" test
```

The normally signed simulator build, rather than the unsigned XCTest host, is installed for the native UI flow so the simulator supplies the app's real Keychain application identifier. An initial unsigned UI attempt correctly showed a safe Keychain-save error; credential handling was not weakened to bypass it.

An intermediate full iOS run reported 790 passed and one native audio test failure: `AudioOutputTests.testEngineConfigurationChangeRestartsStoppedPlayback`, `player did not see an IO cycle`. The final full run used a freshly reset synthetic app state, no concurrent Mac native audio fixture, and serialized testing: all 791 passed. No audio production change, assertion suppression or test exclusion was made for that failure. Four existing `AudioOutputTests` QoS warnings remain. Simulator diagnostic collection can report its subprocess cannot find `simctl` under the global Command Line Tools selection; the completed xcresult independently reports the full passing suite.

## Safety and compatibility coverage

The full suite includes Standard authentication/unsupported readiness, bounded requests, event/ack ordering, admission/generation matching, durable resume, no replay, disconnect/interrupt outcomes, persistence and credential namespace isolation, profile identity edits, save rollback, New/Leave failure guards, background disconnect despite snapshot failure, active/uncertain reconfiguration rejection, setup operation leases, microphone/hands-free teardown, retained pending Home pairing links, and Home diagnostics gating without discarding stored consent/queue.

Existing Home/Legacy tests now assert that rejected switching/clearing preserves active or uncertain transcript/draft state; a deliberate Leave is required before proceeding. Incidental forwarding/wording assertions encountered in affected suites were removed rather than re-pinned.

Older decoders safely ignore the separate Standard profile array instead of treating it as Legacy. **An older app saving the collection drops unknown Standard entries.** Downgrade is not a round-trip preservation guarantee: do not edit/save connection settings in an older build; retain a recoverable configuration copy. README records this limit.

## Delivery and acceptance boundaries

Implementation is ready for review, not marked done. Merge, owner acceptance and deployment remain separate. No physical iPhone/iPad acceptance, deployed Standard endpoint, native Mac end-to-end Keychain setup, direct voice/audio, distribution signing/notarization, or broad migration closure is claimed. The synthetic inference peer verifies native client/agent integration, not a production provider or model. No user-device install, Puck access, production token, global trust-store change or upstream source patch was required.
