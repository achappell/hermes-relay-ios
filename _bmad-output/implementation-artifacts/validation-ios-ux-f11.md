# Validation — IOS-UX-F11 iPhone Duo adaptive layout

Spec: `spec-ios-ux-f11-iphone-duo-adaptive-layout.md`. Status: `in-progress`.
iPhone Duo acceptance is **not yet verified**; current limitations are listed below.

The audit, width-only implementation, probes and fake-relay continuity
evidence through "Evidence status for the Duo simulator" below describe the
earlier width-based implementation. They do not verify the current
fold-aware interface or a live fold with it. Current evidence and limitations
are recorded under "Fold-aware interface".

## Audit (HermesRelay/Views, Info.plist)

- No `UIScreen.main`, orientation-lock API, `UIRequiresFullScreen`, or
  size-class/orientation change handler. Development-Info.plist and the
  generated plist setting list all four orientations; Release-Info.plist has no
  orientation keys. Target family is `1,2`, deployment target iOS 26.
- The HUD stacked its voice stage and transcript at every width. Fixed
  numbers are ceilings or scalable (`CompressibleOrb` 260 pt scaled to 60%,
  rail 52–152 pt, `maxWidth` 360/680/760/900), not minimum widths, so ~466 pt
  does not clip. Configure Relay and the Home sheets are `Form`s with frame
  minimums only on macOS.
- Conversation, voice and lifecycle objects live in `ContentViewRuntime`
  behind `@State` in `ContentView`; the transcript rail's follow/reveal state is
  its own `@State`. Nothing keys view identity on size or size class.

## Historical change — superseded width-only implementation

`AdaptiveVoiceLayout` (`AmbientHUD.swift`) is a `Layout` that places the voice
stage and transcript card with a `VStackLayout` below 600 pt of HUD width and an
`HStackLayout` at or above it (`AmbientHUDLayoutMode`). It is one container with
the same two subviews, so a resize re-places them. It is a `Layout`, not a
`GeometryReader`, so `ViewportFillLayout` still gets a real minimum height and
large Dynamic Type scrolls instead of clipping. The HUD width is the display
width less 32 pt padding: Duo outer ≈ 434 pt (compact), inner ≈ 637 pt
(expanded).

## Automated evidence

All with `DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer`.

- Focused:
  `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -only-testing:"Hermes RelayTests/HermesRelayIOSTests/testAmbientHUDLayoutModeAdaptsAcrossDuoDisplayWidthsAndTransitions" -only-testing:"Hermes RelayTests/HermesRelayIOSTests/testAdaptiveVoiceLayoutReplacesViewsWithoutRecreatingThemAcrossDisplaySwitch" CODE_SIGNING_ALLOWED=NO test`
  → 2 tests, 0 failures. The second hosts the layout, switches 434 → 637 → 434 pt,
  asserts stacked / side by side / stacked, and that each view appeared once.
- Full iOS 27.0 simulator suite, iPhone 18 Pro, same command without
  `-only-testing`: `** TEST SUCCEEDED **`, 793 tests, 0 failures.
- macOS: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`.
- Full suite on the iPhone Duo simulator (iOS 27.2):
  `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'id=4E8482AD-902F-4C1F-A1F5-DBAAFE24D9DE' CODE_SIGNING_ALLOWED=NO test`
  → `** TEST SUCCEEDED **`, 793 tests, 0 failures, run after the probe was removed.

## Screenshots (unconfigured state, no private content)

`docs/screenshots/ios-ux-f11/`:
`iphone-18-pro-portrait-compact.png` (402 pt wide, compact),
`ipad-mini-portrait-expanded.png` (744 pt wide, expanded) and
`duo-outer-466x678-compact.png` (iPhone Duo simulator, outer display, iOS 27.2).
No inner-display screenshot exists: see the Duo probe below.

## iPhone Duo simulator probe (iOS 27.2, 2026-11-09)

Device: the system-provided `iPhone Duo` (4E8482AD-902F-4C1F-A1F5-DBAAFE24D9DE)
on runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4` (iOS 27.2,
24B91016s). It was already present; no `simctl create` was needed.
A throwaway probe (not committed; removed) logged scene, window, size-class and
hinge values through `os.Logger` and `simctl spawn ... log stream`.

Measured on launch, outer display:

- `connectedScenes` = 1 (`UIWindowScene`, role `UIWindowSceneSessionRoleApplication`),
  `UIScreen.screens` = 1.
- Window and screen bounds 466 x 678 pt, native 1398 x 2034 px, scale 3.
- Window safe-area insets: top 0, left 0, bottom 34, **right 84** (the outer
  display reserves a trailing status column). SwiftUI sees the `ContentView` at
  **382 x 644 pt**, so the HUD (16 pt side padding) is **350 pt** wide, not 434.
- Size classes: horizontal compact, vertical regular.
- Hinge: `onHingeChange` delivered `old=nil new=closed@0.0deg` once on launch;
  `UIHingeInteraction` (installed on the root view, enabled) reported status 1
  (closed), angle 0.0.
- Built `Info.plist` has no scene manifest and no
  `UIApplicationSupportsMultipleScenes`; one scene was created regardless.

Consequence for the 600 pt breakpoint: folded, the HUD is 350 pt, compact. The
earlier 553 pt estimate for the inner display was wrong: see the unfold result.

## How the fold was driven

The user dragged the hinge slider in Xcode's Device Hub on the Duo simulator
while the probe streamed its subsystem. There is no command-line way:
`simctl` has no hinge, fold or display-switch command; `simctl io ... screenConfig`
only offers `power` and `geometry` (powering the primary screen off was
followed by SpringBoard `EXC_BREAKPOINT` crashes, recovered by a reboot; do not
use it); `devicectl device simulate` has only biometrics, location, statusBar.
The host control is Xcode's `CoreDevicePopDeviceKitExtension` (`HingeController`,
`hinge-slider-control`), which sends HID events. A physical iPhone19,4 is also
connected to this Mac; it was never used.

## Decisive evidence: unfold (iOS 27.2 Duo simulator, 2026-11-09 20:52)

Scene model: **one scene, resized in place; no recreation.**

| | Folded (outer) | Unfolded (inner) |
|---|---|---|
| connectedScenes | 1 (`UIWindowScene`, `UIWindowSceneSessionRoleApplication`, activation 0) | 1, same scene, activation 0 |
| UIScreen.screens | 1 | 2 (`UIScreenDidConnect` at 20:52:18.517); no second scene |
| process | pid 26200 | pid 26200; one `event=start`, one `UISceneWillConnect` |
| screen.bounds / native | 466x678 pt / 1398x2034 px | 951x669 pt / 2007x2853 px |
| window.bounds | 466x678 | 951x669 |
| scene and effectiveGeometry coordinateSpace | 466x678 | 951x669 |
| interfaceOrientation | 1 (portrait) | 4 (landscape), not locked |
| size classes (h / v) | compact / regular | regular / regular |
| window.safeAreaInsets | T0 L0 B34 R84 | T0 L0 B34 R84 |
| safeAreaLayoutGuide | 382x644 | 867x635 |
| SwiftUI root | 382x644, insets B34 R84 | 867x635, insets B34 R84 |
| HUD width (root less 2x16 pt) | **350 pt, compact** | **835 pt, expanded** |

- The 600 pt breakpoint switches correctly at both real Duo sizes. The inner
  screenshot (`duo-unfolded-LCD-1.png`) shows the side-by-side arrangement.
- The 84 pt trailing inset is a real system safe area, present in both
  states. It is not a compatibility letterbox: window.bounds equals
  screen.bounds and the inset is in `window.safeAreaInsets`. It was identical
  with no `UIApplicationSceneManifest`, with a manifest (multiple scenes false
  and true), and with `UILaunchScreen` removed; Apple's Settings shows the same
  column. A baseline iPhone 18 Pro (iOS 27.2) has window 402x874, insets T62 B34,
  and receives no hinge callbacks. No scene manifest is needed for any of this.
- `UIApplication.supportsMultipleScenes` read false even with the manifest set
  to true (iPhone idiom).
- Hinge sequence (`onHingeChange`, degrees; `UIHingeInteraction` reports the same
  in radians, 3.1416 at 180 deg): 20:19:52.105 launch `old=nil new=closed@0.0`; at
  20:52:18.405 `closed@8.79`; .420 `partiallyOpen@26.6`; .560 `partiallyOpen@93.6`
  (window already 951x669); .670 `partiallyOpen@133.8` (then ~10 repeats of the
  same value to 20:52:19.213); 20:52:20.304..504 `135.5, 142.4, 149.3, 156.1,
  163.0, 169.9`; 20:52:20.538 `fullyOpen@180.0`. Status 2 (partiallyOpen) held
  from about 26 deg to 170 deg.
- Transient mid-fold frame, about 15 ms at ~26 deg: window still 466x678 but
  safe insets top 82, bottom 0; SwiftUI root 466x562 with top 82 / bottom 34;
  then 867x635. Layout must tolerate it without resetting state.
- Probe excerpt (geometry, verbatim shape): folded `window[bounds=(0,0,466,678)
  safeInsets=(top 0,left 0,bottom 34,right 84) safeLayoutGuide=(0,0,382,644)]
  hSize=1 vSize=2 effGeo.orientation=1`; unfolded `window[bounds=(0,0,951,669)
  safeInsets=(0,0,34,84) safeLayoutGuide=(0,0,867,635)] hSize=2 vSize=2
  effGeo.orientation=4 screen.bounds=(951,669) native=(2007,2853)`.
- Screenshots: `duo-outer-466x678-compact.png`, `duo-unfolded-LCD-1.png` (inner,
  expanded). `duo-unfolded-LCD.png` is the now-inactive outer display (near black).
  All are the not-configured state.

The probe was a throwaway in a separate worktree (removed); none of it is in the
feature diff.

## Continuity evidence with a fake relay (iOS 27.2 Duo simulator, 2026-11-09)

A throwaway protocol-v1 fake relay (outside the repo) streamed a 90 s turn
(`message.delta` text growing to 5706 characters, `audio_start`, real-time 24 kHz
PCM tone, `audio_end`, `message.complete`, `turn_end`). A throwaway probe
(separate worktree, not in the feature diff, removed) logged state each second.
The ad-hoc simulator build has no Keychain entitlement, so the probe kept a fake
token in a temp file. The user dragged the Device Hub hinge slider: fold, unfold,
fold back, repeatedly, plus display rotations and a 43 s hold at 133.8 deg.

| Criterion | Result | Evidence |
|---|---|---|
| Connection kept, no reconnect, no replayed turn | PASS | Relay: one connection, one hello and exactly one TURN for the whole run; turn completed 21:04:47. |
| Playback uninterrupted | PASS | `playPos` 0.7 to 90.1 s, monotonic over 209 samples, per-second deltas 0.8-1.3 until the end, voice state `speaking` until `complete`; crossed unfold 21:03:54, fold-back 21:04:01, unfold 21:04:11, rotations 21:04:14/21:04:21, 43 s hold at 133.8 deg. Audibility not checked (position only). |
| Transcript keeps growing | PASS | Reply 252 to 5706 characters, 5 messages, monotonic. |
| Draft kept | PASS | Draft value 16 characters from 21:03:24 through ~20 window changes. (Store value; composer text not inspected.) |
| View identity, no recreation | PASS | One `runtime-created`, no ContentView or rail onAppear/onDisappear after launch, one pid, both runs. |
| Follow/paused state kept | PASS (probe-set) | Probe paused follow at 21:07:46.564; it stayed paused through 5 window changes (fold, unfold, fold, unfold) with no rail re-appear. A real scroll-back drag was not performed. |
| Hands-free arming / active capture | UNTESTED | `handsFreeArmed` and capture false throughout; no tap possible, microphone cannot be driven in the simulator. |

Window behaviour seen (all `connectedScenes=1`, insets R84 B34 when on a
landscape-native or portrait outer window): closed 466x678 portrait
(compact/regular, layout width 382, HUD 350, compact); any partiallyOpen or
fullyOpen reading 951x669 landscape (regular/regular, width 867, HUD 835,
expanded), including the 133.8 deg hold; inner display rotated 669x951 (top
82, width 669, HUD 637, expanded); outer display briefly 678x466 landscape for
5 s after a fold (compact/compact, left 84, width 594, HUD 562, compact).
- The window follows the hinge **status**, not a fixed angle, and the
  angle-to-status mapping depends on direction and history: it flipped to the
  inner window at `partiallyOpen@86.4` in one unfold and `@20.9`/`@30.8` in
  others, and back to the outer window when the status became `closed` (81.2,
  62.3, 57.2 deg). Closed also reported while the angle rose to 93.8 deg.
- Transients at each flip (~15-20 ms): root 466x562 with top inset 82, then
  867x635; duplicate hinge callbacks at the same angle. State survived all.
- Unexplained: with the hinge closed, 21:05:30-21:05:42 showed bottom inset 20
  versus 34 flicker, `UIScreen.screens` 2, and one frame at 466x722.
- One earlier app instance lost its connection by itself before any hinge
  motion (about 21:01:3x); cause not found.

## Open items

- Held 45, 90 and 120 deg postures were not measured (the slider could not be
  held precisely). Only 133.8 deg was held. Evidence so far: the window is the
  inner 951x669 at every partiallyOpen reading and the outer 466x678 when
  closed, so width alone chose correctly at every observed state. If a
  hinge-driven arrangement is wanted, key it on `UIHinge.Status`, not angle.
- The outer display in landscape (678x466, HUD 562, compact) briefly occurred;
  it was not user-driven and no layout was checked there.
- Hands-free arming and active capture across a fold; a real scroll-back drag;
  audible playback (position only was observed).
- Dynamic Type at the Duo sizes.

## Correction: hinge and arrangement APIs exist on iOS 27.1+

An earlier recon claimed the SDK has no fold, hinge or posture API and that
width is the only signal. That is wrong for the iOS 27.1+ SDK (Xcode 27.2); all
of these are `@available` 27.1:

- UIKit: `UIHinge` (`UIHinge.Status` closed / partiallyOpen / fullyOpen, plus
  angle), `UIHingeInteraction`, `UIHingeInteractionUpdate`,
  `UIArrangementViewController` with `UISplitArrangement` and
  `UIOverlayArrangement`.
- SwiftUI: `DeviceHinge`, `DeviceHingeContext`,
  `View.onHingeChange(isEnabled:action:)`, `ArrangementView` with `.split`,
  `.overlay`, `.automatic`.

The historical 600 pt width implementation did not use these APIs. Width remains
the iOS 26 and no-hinge fallback; the current fold-aware interface is described
below.

## Historical design fork — superseded by the fold-aware direction

Scene model A is confirmed: one scene, one process, resized in place, no
second scene (`UIScreen.screens` becomes 2 but `connectedScenes` stays 1). The
"two scenes sharing one session" option is therefore not needed for fold
continuity and would only add per-scene runtimes. At the time, the remaining
choice was width alone versus hinge and arrangement APIs. That design fork has
since been superseded by the fold-aware direction described below.

## Facts checked in the repository

- `ConversationStore` is app-level (built once in `HermesRelayIOSApp.init`).
  `ContentViewRuntime` is built per `ContentView` via its `@State`
  `ContentViewRuntimeBox`, so two scenes would each build their own
  microphone and audio runtime.
- No scene manifest is declared. `Development-Info.plist` has no
  `UIApplicationSceneManifest`. `project.pbxproj` has no `INFOPLIST_KEY_*` scene
  key (no text containing "Scene" at all, so neither
  `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` nor
  `UIApplicationSupportsMultipleScenes`). Debug: `GENERATE_INFOPLIST_FILE = NO`,
  `INFOPLIST_FILE = HermesRelay/Development-Info.plist`. Release:
  `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_FILE = HermesRelay/Release-Info.plist`,
  which also has no scene key. `plutil -p` of the built Debug iphonesimulator
  `Info.plist` (iOS 27.0 build) shows no scene manifest and no
  `UIApplicationSupportsMultipleScenes`. The app declares one SwiftUI
  `WindowGroup`.

## Fold continuity acceptance criteria (not yet exercised)

Across a fold, unfold, display switch or resulting scene/window resize:

1. Playback continues uninterrupted.
2. Active capture and hands-free arming are kept.
3. Transcript scroll and follow/pause state are kept.
4. Conversation, draft and connection are kept: no reconnect and no replayed
   turn.

The existing identity test only shows that the stage and transcript views are
not recreated by a width change in the hosting harness. It says nothing about
capture, playback, the runtime, or a real fold.

## Evidence status for the Duo simulator

Obtained (see "Decisive evidence: unfold"): connectedScenes before and after
(1 and 1), window size before and after (466x678 to 951x669), the built-plist
scene manifest (none; manifest variants change nothing), `onHingeChange` values
while moving. Still missing: values with the hinge **held** at intermediate
angles, fold-back, outer landscape, and any session-state continuity.

## Fold-aware interface — 2026-11-10

The iOS 27.1+ view uses the detected hinge, active division and system split
arrangement; the iOS 26 and no-hinge paths retain the existing layout. The
outer-mode choice is session-local. The transcript, composer and voice stage
remain children of one workspace layout across Duo posture changes.

Focused iPhone Duo iOS 27.2 simulator XCTest run: 2 tests, 0 failures.
`testDuoWorkspaceMovesExistingControlsAroundActiveDivision` checks hosted
layout placement in open, book, RTL book and laptop arrangements and checks
that its five probe children appear only once across transitions.
`testDuoTranscriptShowsFullHistoryDuringLiveCapture` checks transcript
projection with history and provisional speech. These are not end-to-end
fold, keyboard, capture, playback, VoiceOver or real-device tests; those
checks remain open. Xcode emitted an `invalidDigitCount(91016)` simulator
version warning despite the successful test result.

### Simulator interface check

On the booted iPhone Duo iOS 27.2 simulator, an unconfigured launch on
`LCD-1` showed the transcript and composer above the voice stage (the
laptop-style arrangement). See `docs/screenshots/ios-ux-f11/duo-laptop-current.png`.
At `accessibility-extra-extra-extra-large`, the prior screenshot still showed
clipped status text and a clipped Configure relay button. After reflowing the
header and panel viewports and allowing an empty transcript's space to be used
by the composer region, the replacement screenshot
`docs/screenshots/ios-ux-f11/duo-laptop-accessibility-xxxl.png` shows the
complete unconfigured status and Configure relay button. In that screenshot
the composer is below the visible portion of its scrollable region.

After this reflow, three focused hosted layout tests passed (3 tests,
0 failures), covering an oversized composer with and without transcript
content and workspace posture/RTL placement. The final post-reflow arm64 macOS
build succeeded, as recorded in "Final regular-phone and macOS check" below.

An isolated, throwaway XCUITest runner then exercised the real unconfigured
app at the same accessibility text size on the inner display. It tapped the
composer; XCUITest reported scrolling it into view, the keyboard existed in
the accessibility tree, and typing and deleting synthetic text succeeded.
It also tapped `doorway-primary-action` and observed the Configure Relay
navigation bar. Both targeted UI tests passed. The keyboard's presence in
the accessibility tree does not establish its physical panel or visible key
geometry; the captured inner-screen image did not show keyboard keys.

The outer-toggle check did not pass: while the visible app was on the inner
display, XCUITest nevertheless reported the hidden `duo-view-toggle` as
hittable; tapping Transcript left Talk selected. XCUITest exposed three
screens, with the main-screen screenshot black and the app visible on a
different screen. This result cannot distinguish simulator screen routing from
an accessibility/hit-testing defect. At that point no outer-display fold could
be driven through the available `simctl` or public XCUITest controls, and
outer-mode interaction, fold continuity, and active voice controls were
unverified. See the later closed-display interaction below.
The throwaway runner was removed and simulator text size restored to `large`.

The outer-mode Picker is now inserted only for the outer display; the inner
workspace uses a noninteractive, accessibility-hidden placeholder, while the
stateful transcript, composer and voice children remain in place. The earlier
failed live-toggle test is not evidence of a successful interaction.

A recreated throwaway XCUITest then launched the unconfigured app on the
iPhone Duo iOS 27.2 simulator, captured its inner display, and asserted that
no accessibility descendant had the identifier `duo-view-toggle`: 1 test,
0 failures. The attachment showed the app on the inner display. This verifies
absence in that current posture only; it does not verify an outer-mode tap or
a live fold. Xcode emitted `invalidDigitCount(91016)` despite the successful
result. The temporary test project and runner were removed.

### Closed outer display interaction — 2026-11-10

After the user closed the iPhone Duo iOS 27.2 simulator hinge, a throwaway
XCUITest launched the actual unconfigured app and observed the outer
`duo-view-toggle`. Talk was initially selected. XCUITest tapped Transcript and
confirmed it selected, tapped the composer and found a keyboard accessibility
element, then tapped Talk and confirmed it selected. This verifies the live
outer controls in the unconfigured state, not physical keyboard visibility,
VoiceOver speech, or connected voice continuity. After the simulator reopened,
the same test confirmed the outer segmented control was absent: **TEST
SUCCEEDED**, 1 test, 0 failures. Xcode emitted `invalidDigitCount(91016)`.
Result bundle: `~/Library/Developer/Xcode/DerivedData/.DuoAcceptance-hjymhtxhakrpbwejlocfakvmqmhu/Logs/Test/Test-DuoAcceptance-2026.11.10_07-53-33--0600.xcresult`.

### Fake Home relay fold probe — 2026-11-10

An isolated simulator bundle used the current workspace views, store and
coordinator with an in-memory fake Home client and synthetic silent PCM and
text; it used a separate sandbox and no real credentials. While the user folded
the Duo, sampled state stayed connected with one open, no reconnect, one turn
and an unchanged synthetic draft; transcript length rose from 142 to 602
characters and playback position from 11.93 to 58.19 seconds. The closed-screen
view showed Connected and Speaking. This is a playback-clock observation, not
audibility.

At 08:19:37 CST the first probe reached the default 120-second Home control
terminal deadline because the fake sent no `turn.alive`; it disconnected and
the turn failed before reopening was confirmed. The last connected sample
showed 1,212 transcript characters and 119.59 seconds of playback; after the
timeout the draft remained, the transcript stopped at 1,222 characters, and
one submitted turn was recorded. Thus this run does not establish active
reply continuity through reopening.

A second probe also timed out at 120 seconds: it emitted `turn.alive` but the
fake did not advertise the `turnKeepalive` capability. The corrected fake
advertised that capability and sent keepalives every 10 seconds, with the
production deadlines unchanged. It was started while the simulator was closed;
the user then reopened it during the active reply. Across 306 samples from
17:57:15 to 18:02:22 CST, the same process remained connected with one fake
open, zero reconnects, one submitted turn, and the synthetic draft unchanged.
Transcript length increased from 22 to 3,072 characters. Once playback started,
its position increased monotonically from 0.79 to 306.87 seconds, with
successive sampled increments between 0.98 and 1.09 seconds. After reopening,
the inner-screen screenshot showed Connected, Speaking, the live transcript and
the unsent synthetic draft. The earlier open-to-closed and corrected
closed-to-open observations were separate runs, not one round trip. These
fake-relay probes did not verify a network socket, real audio audibility,
active capture, VoiceOver, or scroll-follow state across a fold; the separate
synthetic listening and follow test below covers part of that remaining scope.

### Synthetic listening and transcript follow — 2026-11-10

A separate simulator-only bundle used the production workspace, coordinator
and transcript rail with a synthetic `SpeechInput`, in-process fake Home
client and 30 synthetic history entries. XCUITest tapped the voice orb, swiped
the actual transcript scroll view and observed **Resume live**. After the user
folded the Duo, XCUITest selected Transcript and found **Resume live** still
present: **TEST SUCCEEDED**, 1 test, 0 failures. This checks the
consumer-visible paused-follow control, not the exact scroll offset or resumed
following of subsequently streamed text.

In 204 samples between 18:06:26 and 18:09:55 CST, the same process and fake
connection remained present. After the tap the coordinator remained listening
through folding with one synthetic input start, zero cancels, one fake open,
zero reconnects, an unchanged synthetic draft and 30 history entries. No real
microphone, Apple speech capture or recognition was exercised; VoiceOver speech
and focus continuity were not tested.

### Final integrated simulator suite

After the fold-aware UI and coordinator changes, the full iOS suite ran on the
iPhone Duo iOS 27.2 simulator with Xcode 27.2:

`xcodebuild test -project "Hermes Relay.xcodeproj" -scheme HermesRelay -derivedDataPath /tmp/hermes-duo-integrated-voice -destination 'platform=iOS Simulator,id=4E8482AD-902F-4C1F-A1F5-DBAAFE24D9DE'`

Result: **TEST SUCCEEDED**, 806 tests, 0 failures. This automated suite is not
evidence of a live fold, VoiceOver interaction, physical keyboard placement,
active capture across a fold, or real-device validation.

### Final regular-phone and macOS check

Built and launched the unconfigured app on the iPhone 18 Pro iOS 27.0
simulator. `docs/screenshots/ios-ux-f11/iphone-18-pro-ios-27-final.png`
shows the normal voice-first surface with the orb, recovery action and
composer; this is an iOS 27.0 visual launch check, not a connected voice
interaction. The final arm64 macOS build succeeded. `xcodebuild
-showBuildSettings -json` reported the app target's effective iOS deployment
target as 26.0; that target setting is build compatibility, not an iOS 26
runtime test. No iOS 26 runtime test is claimed.

### Fully open header alignment

On the iPhone Duo iOS 27.2 simulator, a separately installed fixture used the
production conversation view with an in-process fake Home connection and
synthetic transcript. The fully open layout places the session and bridge
cards in the leading voice column, with Disconnect aligned at the top trailing
edge; the transcript starts alongside the cards. The inspected screenshot is
`docs/screenshots/ios-ux-f11/duo-open-header-aligned.png`.

Focused hosted layout tests for open/inner placement, RTL and preserving child
identity passed: 2 tests, 0 failures. A throwaway XCUITest on the connected
fixture verified the bridge card stayed left of Disconnect, the session gear
and Disconnect aligned, and Disconnect had a 44-point height and was hittable;
tapping it disconnected the fake session. Result: 1 test, 0 failures. Xcode
emitted `invalidDigitCount(91016)`. The fixture does not validate a real
connection or VoiceOver. The earlier full-suite result predates this change.

Post-alignment macOS arm64 build:
`xcodebuild -project 'Hermes Relay.xcodeproj' -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`
— **BUILD SUCCEEDED**. Xcode noted that the audio background mode is not
supported on macOS and skipped App Intents metadata extraction because there
is no AppIntents dependency.
