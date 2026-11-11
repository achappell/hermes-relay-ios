# IOS-UX-F11 — Support iPhone Duo adaptive layout and continuity

## User outcome

Hermes Relay remains usable on Apple's dual-display iPhone Duo across its outer and inner displays, including a live window-size transition between them. On iOS 26 layout responds to available container width; the iOS 27.1+ SDK also exposes hinge and arrangement APIs, which are an open design option below.

## Scope

- Support iPhone19,4 (iPhone Duo), idiom phone, with an outer display of 1398×2034 px at 3× (~466×678 pt) and an inner display of 2007×2853 px at 3× (~669×951 pt, native landscape).
- Keep iOS deployment target at 26.0. The 600 pt width breakpoint is the iOS 26 path and the fallback below iOS 27.1. iOS 27.1+ adds hinge, arrangement and `onHingeChange` APIs (see "Platform signals (correction)"); using them is gated with `#available(iOS 27.1, *)` and is the open design fork below.
- Audit the HUD, transcript rail, history sheet, Configure Relay, visualizer, controls, orientation handling and plist orientation/full-screen restrictions for these bounds and live transitions.
- Use a compact arrangement on narrow containers and a useful wider arrangement on the inner display; do not duplicate stateful transcript or control views.
- Preserve conversation, transcript scroll/follow/reveal state, active capture, and audio playback while scene size or display changes.

## Acceptance criteria

1. The app supports both Duo display sizes, device orientations, safe areas and dynamic container resizing without clipped/unreachable primary controls or fixed-screen assumptions.
2. The HUD selects compact layout around 466 pt and a wider HUD/transcript arrangement around 669 pt using available container size; changing between modes does not reset view-owned state.
3. A live Duo display/window transition preserves the current conversation, transcript position/follow state, active capture and audio playback; size changes do not create or reset the runtime/coordinator.
4. No orientation restriction or `UIRequiresFullScreen` setting prevents the supported Duo layouts; the deployment target remains iOS 26.
5. Deterministic tests cover compact/expanded layout selection at both Duo widths and a compact→expanded→compact transition. Run focused tests, iOS 27.0/27.2 simulator tests, and the macOS build. When available, launch on Duo, capture both display layouts and exercise a transition with session state present.

## Deterministic validation scenario

Evaluate layout mode at 466 pt, 669 pt, then 466 pt and assert compact, expanded, compact. Inspect the same HUD state-bearing view hierarchy across the transition; verify its shared view tree retains transcript follow/reveal state and the conversation/runtime remains rooted outside the responsive layout. On device/simulator, start a voice capture and inbound playback before changing displays and confirm they continue without a view identity reset.

## Platform signals (correction)

An earlier recon of this story claimed the SDK has no fold, hinge or posture API and that available width is the only signal. That is wrong for the iOS 27.1+ SDK (Xcode 27.2). All of the following are `@available` 27.1:

- UIKit: `UIHinge` (`UIHinge.Status`: closed / partiallyOpen / fullyOpen, plus an angle), `UIHingeInteraction`, `UIHingeInteractionUpdate`, and `UIArrangementViewController` with `UISplitArrangement` and `UIOverlayArrangement`.
- SwiftUI: `DeviceHinge`, `DeviceHingeContext`, `View.onHingeChange(isEnabled:action:)`, and `ArrangementView` with `.split` / `.overlay` / `.automatic`.

The current implementation (`AmbientHUDLayoutMode`, a 600 pt width breakpoint) uses width only. It remains the iOS 26 path and the fallback below iOS 27.1, since the deployment target stays 26.0. It was not derived from hinge state; on the Duo simulator it nevertheless switches correctly at the real folded (350 pt HUD) and unfolded (835 pt HUD) sizes.

## Design fork (narrowed: scene model A confirmed)

1. **One adaptive scene, hinge-driven arrangement.** Primary candidate on iOS 27.1+, gated with `#available(iOS 27.1, *)`. One scene and one `ContentViewRuntime`; hinge status and `ArrangementView` (`.split` / `.overlay` / `.automatic`) choose the arrangement. The 600 pt width breakpoint stays as the iOS 26 fallback.
2. **Two scenes sharing one session.** Separate scenes for the outer and inner display, sharing one conversation session and one mic/audio runtime. Requires lifting the runtime out of `ContentView` (see facts) and a scene manifest.
3. **Mirror-only.** One scene shown on whichever display is active, with no arrangement change beyond what the system provides.

## Facts that constrain the fork

- `ConversationStore` is created once in `HermesRelayIOSApp.init` and passed to the single `WindowGroup`'s `ContentView`, so it is app-level. `ContentViewRuntime` (audio activity store, voice coordinator, lifecycle coordinator) is built per `ContentView` through that view's `@State` `ContentViewRuntimeBox`. Two scenes would therefore each build their own microphone and audio-playback runtime, and each would run its own lifecycle coordinator against the shared store.
- No scene manifest is declared. `Development-Info.plist` has no `UIApplicationSceneManifest`. In `project.pbxproj` no `INFOPLIST_KEY_*` scene key exists (`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, `INFOPLIST_KEY_UIApplicationSupportsMultipleScenes`, and any key containing "Scene" are all absent; the file has no "Scene" text at all). Debug uses `GENERATE_INFOPLIST_FILE = NO` with `INFOPLIST_FILE = HermesRelay/Development-Info.plist`; Release uses `GENERATE_INFOPLIST_FILE = YES` with `HermesRelay/Release-Info.plist`. `Release-Info.plist` has no scene key either. The built Debug `Info.plist` (iphonesimulator, iOS 27.0 build) was dumped with `plutil -p` and contains no scene manifest and no `UIApplicationSupportsMultipleScenes`. Whether the Duo needs one for a second scene or for a display change is not yet known.

## Fold continuity acceptance criteria

Across a fold or unfold, a display switch, and any scene or window resize it causes:

1. Inbound audio playback continues without an audible gap, restart or stop.
2. An active capture continues, and hands-free arming stays armed or disarmed exactly as it was.
3. Transcript scroll position and follow/pause state (including "Resume live") are kept.
4. The conversation, the unsent draft and the connection are kept. There is no reconnect, no new session and no replayed turn; an unconfirmed turn stays unconfirmed.

These apply to whichever design is chosen.

## Evidence from the Duo simulator (iOS 27.2, 2026-11-09)

Recorded in `validation-ios-ux-f11.md`. Summary:

1. **Scene model A confirmed.** On unfold `connectedScenes` stays 1 (same scene, same process, no new launch), `UIScreen.screens` goes 1 to 2 with no second scene, and the window is resized in place from 466x678 to 951x669 pt (portrait to landscape, size classes compact/regular to regular/regular). No `UIApplicationSceneManifest` is needed; adding one (multiple scenes false or true) or removing `UILaunchScreen` changes nothing.
2. **The 84 pt trailing inset is a real system safe area** (`window.safeAreaInsets` T0 L0 B34 R84 in both states, window equals screen), not a letterbox. HUD width is 350 pt folded and 835 pt unfolded, so the 600 pt breakpoint switches correctly at both real sizes.
3. **Hinge sequence** observed by `onHingeChange`: closed 0, 8.8, partiallyOpen from 26.6 through 169.9 deg, fullyOpen 180. At 93.6 deg the window was already 951x669. A transient ~15 ms frame at ~26 deg had window 466x678, top inset 82, SwiftUI root 466x562.

## Continuity evidence and open items

Fake-relay run on the Duo simulator (details in `validation-ios-ux-f11.md`): with a live 90 s turn, a growing transcript and a draft, repeated fold, unfold, fold-back and rotations kept one connection (one hello, one turn, no replay), uninterrupted playback position, the draft, view identity (no runtime or view recreation) and a paused follow state. Hands-free arming and active capture are untested (not drivable in the simulator). The window follows hinge status (closed outer 466x678, any partiallyOpen/fullyOpen inner 951x669), and width alone chose the right layout at every observed state.

Open: held 45/90/120 deg postures were not measured; a real scroll-back drag, audible playback, outer-landscape layout and Dynamic Type at Duo sizes are unchecked. If hinge-driven arrangement is pursued, key on `UIHinge.Status`, not angle. Width remains the iOS 26 fallback.
