---
name: Hermes Relay
status: draft
scope: conversation voice controls and iPhone Duo posture layouts
sources:
  - _bmad-output/implementation-artifacts/ios-visual-design-pass.md
  - docs/superpowers/specs/2026-08-30-ios-voice-interface-design.md
  - docs/plans/2026-09-09-ios-16-hands-free-barge-in.md
  - _bmad-output/implementation-artifacts/spec-2-1-ios-capture-acknowledgement-and-live-transcription.md
  - _bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md
  - _bmad-output/implementation-artifacts/spec-2-2-ios-disconnected-state.md
  - docs/plans/2026-08-30-ios-voice-interface-testing-plan.md
  - _bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-large-layout-2026-10-10/LAYOUT.md
  - _bmad-output/implementation-artifacts/spec-ios-ux-f11-iphone-duo-adaptive-layout.md
  - _bmad-output/implementation-artifacts/validation-ios-ux-f11.md
  - https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
  - https://developer.apple.com/documentation/swiftui/reservedregion
  - https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification
updated: 2026-11-09
---

# Hermes Relay — Experience Spine (conversation)

> Scope: conversation voice and iPhone Duo posture behavior. Paired with [DESIGN.md](DESIGN.md); tokens are referenced as `{path.to.token}`. The spines win on conflict with mocks, earlier specs and the sources above. Decisions and their reasons are in `.memlog.md`. The 2026-10-10 large-layout proposal remains pending approval; its unrelated choices are not adopted here.

## Foundation

- **Form factor:** iPhone first; the same conversation screen on macOS. Hands-free is iOS-only (as today).
- **UI system:** native SwiftUI on iOS 26 / macOS 26, the Night Console tokens in DESIGN.md, and Liquid Glass limited to the typing surface and small controls.
- **Stakes:** polished enough to show people. A first-time user who taps the big orb must be able to talk without instruction.
- **Purpose of the screen:** voice-focused conversation. Voice is primary; typing is secondary.

## Information Architecture

The regular conversation screen has four zones (see DESIGN.md Layout). Duo's outer Transcript view is an explicit exception: it combines transcript, typing and its small voice action.

| Zone | Owns | Does not own |
|---|---|---|
| Header | Profile, conversation title, connection and recovery | Voice actions |
| Voice | Starting, sending, cancelling and interrupting speech; hands-free | Typed input |
| Reply rail | The latest exchange, normally in step with speech; accessible complete response when audio cannot be heard | Controls |
| Typing | Recent prompts, composer, send | Voice capture |

This supersedes the 2026-09-11 rule that the bottom surface owns capture: voice now lives with the orb.

On Duo's outer display, Talk-focused and Transcript-focused are distinct modes, not a combined full Talk surface and transcript. A small toggle nearer the bottom controls in both views switches Talk and Transcript. Transcript-focused includes a small voice action. Start in Talk mode on app launch; within an app session, closing Duo restores the last-used outer mode. Do not persist that choice across launches. Other Talk controls and exact presentation remain open. The inner display prioritizes transcript. Physical panel placement in book and laptop postures is specified under Responsive & Platform.

The outer Talk view includes the orb, status line and visible Keep listening hands-free control. Its desired handoff changes and current implementation differences are noted below. On the outer display, typing belongs in Transcript view, not Talk view; the transcript remains visible during voice capture. Other controls and exact presentation are not decided or excluded.

During an otherwise healthy foreground switch between outer Talk and Transcript views, active recording or reply continues uninterrupted, as with a fold. Retain the transcript and draft, and expose the voice controls appropriate to the ongoing state in the destination view; the transcript stays visible in Transcript view during capture. Actual backgrounding or connection loss follows the disarm and recovery rules below.

The outer header contains the profile name, connection status and a settings button.

## Voice and Tone

Plain, short, action-first. Where an action is available, the status line reads "State · Action"; hands-free waiting/hearing and disconnected states use state alone.

| Moment | Status line | Orb glyph |
|---|---|---|
| Connected, idle | Ready · Tap to talk | mic |
| Listening (tapped) | Listening · Tap to send | stop |
| Your words recognised, finishing | Transcribing · Tap to send | stop |
| Hermes working | Thinking · Tap to interrupt | hand |
| Hermes speaking | Speaking · Tap to interrupt | hand |
| Hands-free on, waiting | Listening for speech | ear |
| Hands-free on, hearing you | Hands-free listening | waveform |
| Not connected | Unavailable / Connecting… / Configure a relay to begin | connection glyph |

- Cancel link: "Cancel".
- Hands-free pill: "Keep listening". No caption. Its accessibility hint, and a one-time tip shown in place of the status line's action the first time it is turned on, read: "Talk, pause, and Hermes answers. Tap the orb to interrupt."
- Voice interruption setting (Settings): "Interrupt Hermes by talking (headphones only)".
- Blocked states say why, e.g. "Hands-free is on. Turn it off to talk by tapping."

## Component Patterns

### Voice orb

- The talk control on the regular voice screen. Tapping it performs the action its glyph shows. Duo outer Transcript-focused mode has a separate small Start talking action while that mode is shown; see below.
- Tappable only when connected and not in a state where a tap is blocked (hands-free waiting or hearing you, or an action already in flight that is not an interrupt).
- The bottom-bar microphone button and its "Tap to record" label are removed.

### Outer Transcript-focused voice action

The small voice action changes with the session state; the transcript remains visible. During tapped recording, a separate Cancel discards without sending. The outer-mode toggle nearer the bottom controls provides a path back to Talk. Both voice actions have at least a 44 pt hit target.

| Session state | Voice action and accessible label | Availability and separate Cancel |
|---|---|---|
| Connected idle | Start talking | Enabled when capture is permitted; starts capture. |
| Tapped recording / transcribing | Send early | Enabled when early send is available; sends the captured speech. Cancel is separately available while the tapped recording is listening, and discards it. |
| Thinking / buffering / speaking | Interrupt | Enabled when interruption is available; interrupts and follows the regular voice behavior. |
| Hands-free waiting / hearing you | No tap action | Disabled, matching the regular orb; expose the current state. |
| Hands-free reply | Interrupt | Enabled when interruption is available and remains in hands-free. |
| Complete (hands-free off) | Start talking | Enabled when capture is permitted; starts capture while Complete remains visible until the next capture begins. |
| Disconnected, reconnecting or unavailable | No capture action | Disabled or non-button, matching the regular orb; explain the connection state. |

Expose the listed action as the accessibility label, the current voice state as its value, and a hint describing what activation does. The separate action is labelled "Cancel", with a hint that it discards the recording without sending. Announce meaningful state changes once. Exact presentation and traversal order remain open.

### Outer-mode toggle

The small toggle is visible nearer the bottom controls in both outer views and switches between Talk and Transcript. Expose its purpose and selected mode to accessibility services; each interactive target is at least 44 pt. Exact coordinates and visual treatment remain open.

### Status line and Cancel

- Status line directly under the orb. Cancel appears under it only while a tapped recording is listening; it discards without sending.

### Hands-free pill ("Keep listening")

- A small pill under the status line; tapping toggles Keep listening. Off is outlined, on is filled. If requested during a tapped recording, show "Keep listening · Pending"; its accessibility hint says "Tap again to cancel the request." Tapping it again cancels the pending request. After successful submission, show "Keep listening · On" while Hermes replies: it is armed but does not monitor speech until the reply finishes. While armed and waiting, the status reads "Listening for speech"; while hearing, working or speaking, show the corresponding state and action from the state table. Accessibility: a toggle button, label "Keep listening", value Pending/On/Off as applicable, hint as in Voice and Tone. Announce this meaningful transition once, not every recognition or audio frame. While hands-free is armed, outer Transcript view shows a small Keep listening control with its armed state and permits disarming without switching views. It retains the accessible toggle label, On value and minimum 44 pt hit target. Its appearance when disarmed is undecided.
- Arms conversation mode: listen, send on a pause, answer, listen again.
- Never newly arm automatically on launch, connection or after a reply. If already armed, remain armed and resume monitoring after the reply. Disarm when the app leaves the foreground or the connection drops (as today).

### Recent prompts

- One small clock button left of the composer, only when there is history (replaces the ▲▼ arrows).
- Tapping it opens a native menu titled "Recent prompts": up to 8 of your recent typed prompts, newest first, each on one line (truncated). Choosing one puts it in the composer, focused, to edit or send; it never sends by itself.
- Typed prompts only, in memory only (never saved), cleared when the active Profile changes.
- Accessibility: button label "Recent prompts"; each menu item reads the prompt text.

### Reply rail

- While you talk: your live words (required by story 2.1).
- Normally, while Hermes is thinking: no reply text, only the status line; while it speaks, its reply appears in step with audio, word by word where speech timing exists, sentence by sentence otherwise.
- A person who cannot hear the reply audio can explicitly select in Settings to show the complete response as soon as available instead of waiting for spoken-word reveal. Reveal final text when a successful final-text-bearing completion is available; do not wait for audio drain. Message completion and turn termination vary by transport, and interrupted/error outcomes must not be represented as successful completion. The current Standard client treats `message.complete` with successful status as final text and turn terminal (`HermesRelay/Services/StandardSessionClient.swift:618–642`); the shared normalizer separately represents message and turn completion (`HermesRelay/Services/HermesEventNormalizer.swift:56–73, 180–193`). Exact transport event/status mapping and failure handling must be confirmed during implementation; these source references do not claim live-server verification. Keep this device-wide preference shared across Hermes profiles and enabled across app launches until turned off. Turning it on during a reply reveals the completed response as soon as it is available. Turning it off during a reply leaves already-visible text visible; only future replies return to speech-synchronized reveal. Make the selection accessible. Syncing across devices and automatic detection remain unspecified. The full text is also in History.

## State Patterns

Visual reference: [key-conversation.html](mockups/key-conversation.html) illustrates regular-phone ready, listening, speaking, hands-free and light states. The spine wins on conflict.


| State | Orb | Tap does | Rail | Hands-free pill |
|---|---|---|---|---|
| Idle | mic, still | Start listening | Last exchange | Enabled |
| Listening (tap) | stop, live | Send now | Your live words | If requested, show "Keep listening · Pending"; tapping it again cancels the pending request; cancellation or connection drop clears it |
| Transcribing | stop | Send now | Your words | If a tapped recording remains active and Keep listening was requested, show "Keep listening · Pending"; tapping it again cancels the request; cancellation or connection drop clears it |
| Thinking | hand, attention | Interrupt, then listen | Normally no reply text; accessible complete response when available | Enabled |
| Buffering / Speaking | hand, attention | Interrupt, then listen | Normally follows audio; complete response as soon as available for someone unable to hear it | Enabled |
| Hands-free waiting | ear | Nothing (disabled) | Last exchange | On |
| Hands-free hearing you | waveform | Nothing (disabled) | Your live words | On |
| Hands-free, Hermes replying | hand | Interrupt (stays in hands-free) | Normally follows audio; complete response as soon as available for someone unable to hear it | On |
| Complete (hands-free off) | mic | Start talking | Complete response remains visible until the next capture begins | Off |
| Not connected | connection glyph | Nothing (not a button) | Cached exchange, labelled | Hidden |

For a reply when hands-free is not armed, successful delivery settles in a visible Complete phase after the turn terminal event and all output drains, per [Story 1.2](../../../implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md:67-69). This visible phase is distinct from making final text available for the full-response setting; it remains stable until the next local capture or send. While Complete remains visible, the voice control offers Start talking; beginning the next capture ends the Complete phase. **User-approved presentation override:** after a hands-free reply, the status goes directly back to listening, without briefly showing Complete. The current coordinator sets Complete and manages a reply tail before restarting monitoring; the approved presentation is desired behavior, not a claim about the implementation. If audio cannot start or fails, retain the completed text and identify audio as unavailable rather than showing Speaking. Exact Complete copy remains open.

For disconnected, reconnecting or unavailable states, retain and identify safe cached transcript and draft, show the appropriate Connect or Retry path, and mark an unconfirmed turn. Never automatically replay it; resend requires an explicit user action. Connected means a fresh verified session. See [Story 2-I-2](../../../implementation-artifacts/spec-2-2-ios-disconnected-state.md).

If microphone permission is denied, identify microphone access as blocked; if speech recognition permission is denied, identify speech recognition as blocked. Offer an "Open Settings" action for permission recovery and retain the last safe transcript and draft. If speech recognition is restricted by Screen Time or device management, identify the restriction and explain that Settings may not be able to change it; do not imply the action can override that restriction. Keep these permission states distinct from relay recovery.

If capture ends with no recognized text, do not submit an empty turn. Return to idle unless a pending Keep listening request should arm and start monitoring immediately; Cancel also submits nothing. See [Story 2-I-1](../../../implementation-artifacts/spec-2-1-ios-capture-acknowledgement-and-live-transcription.md).

A request to turn on Keep listening during a tapped recording arms it as soon as that recording ends, rather than asking the person to finish first. Show "Keep listening · Pending" during capture; tapping it again cancels the request. If recognized speech is submitted successfully, show "Keep listening · On" while Hermes replies: it is armed but waits until the reply finishes before monitoring speech. If capture ends with no recognized speech, do not submit an empty turn; arm Keep listening and start monitoring immediately. If the recording is cancelled or the connection drops, clear the pending request and do not arm. Existing echo-safe barge-in rules remain; the pending-request handoff does not monitor speech during a successful reply. The current coordinator instead rejects arming while a tapped capture task exists (`VoiceSessionCoordinator.armHandsFree`); this is desired behavior, not implemented.

## Interaction Primitives

- **Tap to talk, pause to send.** A tapped recording ends on its own after about 1.5 s of quiet (the existing hands-free silence endpoint, which tolerates a 1 s conversational pause) and sends. Tap the orb to send early; Cancel to discard.
- **Tap to interrupt.** During a reply, tapping the orb interrupts; outside hands-free it then starts listening.
- **Voice interruption is opt-in.** Off by default. When on, speaking during a reply interrupts only on echo-safe headphone routes (wired, Bluetooth HFP/LE); on the built-in speaker, interrupting stays tap-only.
- **Keyboard.** On the regular voice screen, focusing the composer lets typing own the screen; the voice zone scrolls. Talking is one tap on the orb once the keyboard is down. Duo laptop posture while typing has the distinct goal described below.
- **Fold continuity.** For an otherwise healthy foreground posture or display change, preserve conversation and connection, the draft, transcript scroll position and follow/pause state, in-progress playback and turn, and active hands-free capture. Do not reconnect or replay a turn merely because the layout changes. This is the desired behavior, not a claim that all cases have been verified.
- A foreground fold or resize is not itself backgrounding or connection loss: the existing hands-free disarm rules still apply if either actually occurs.

## Accessibility Floor

- The orb is one button: label "Voice", value = current state, hint = what a tap does (e.g. "Starts listening.").
- Regular voice-screen VoiceOver order: Profile → state (orb) → Cancel / hands-free pill → reply rail → typing. Outer Transcript view order: header and connection status → transcript → composer and Send → voice action and Cancel when available → Keep listening when armed → Talk/Transcript toggle.
- Announce state changes once, not every recognition or audio frame.
- Reduced motion freezes the orb rings and glyph pulse; the status line still carries state.
- Hit targets: orb 260 pt, Cancel and the hands-free pill at least 44 pt (the pill's hit area extends beyond its 30 pt height).
- Every state is readable without colour.
- In Duo book and laptop postures at larger Dynamic Type sizes, keep the active, state-appropriate talk, Cancel or Interrupt action visible; transcript history and secondary controls may scroll. This does not require all three actions at once.
- Across a foreground posture, display or outer-mode change, preserve VoiceOver and hardware-keyboard focus on the equivalent control and retain the composer's selection when possible. If an outer Talk/Transcript switch removes the VoiceOver-focused control, move VoiceOver focus to the mode toggle and announce the new view. Other focus-loss destinations and traversal remain open; fold/resize preserves focus when the control remains.
- The outer Transcript-focused voice action and separate Cancel expose their action, state and at least a 44 pt hit target as specified above.
- Transcript updates must not move reading focus or announce every live update; this does not override the explicit outer-mode switch focus fallback above. Preserve user-controlled follow/pause and discoverable, non-disruptive access to completed text; when playback fails, identify audio as unavailable. If the user has scrolled back and paused follow, preserve their scroll position rather than jumping when the completed response becomes available. The accessible complete-response selection in Settings is specified in Reply rail.
- At large text sizes, avoid clipping essential actions and keep them operable around the fold; both early send and discard must be reachable during tapped capture across outer, fully open, book, laptop and regular-phone contexts. In laptop posture, keep the composer and active voice action reachable around the keyboard's actual position; transcript history may scroll and secondary controls may move out of view. Validate with keyboard up and down. Exact layout remains open.

Open interaction questions: Define response completeness from the relevant completion event before implementation; do not infer event semantics. Cross-device syncing and automatic detection for the full-response setting remain unspecified.

## Key Flows

> [ASSUMPTION] Drafted from recorded observations, not from a narrated session (Amanda chose not to narrate one). For review.

### 1. Jensen asks a quick question

1. Jensen opens the app. The screen says "Ready · Tap to talk" under a big microphone orb.
2. She taps the orb, as she always tried to. It turns live and the status reads "Listening · Tap to send".
3. She asks her question; her words appear in the rail as she speaks.
4. She stops talking. **Climax:** without another tap, Hermes takes it: "Thinking · Tap to interrupt".
5. Hermes answers aloud; the words appear in step with the voice.
6. In this non-hands-free flow, after output drains, the response settles visibly as Complete; the subsequent transition is open.

### 2. Amanda talks hands-free while cooking

1. Amanda turns on "Keep listening" under the orb. The status reads "Listening for speech".
2. She speaks, pauses; Hermes answers aloud.
3. Hermes finishes and the app listens again without a touch.
4. The TV is on in the background. **Climax:** Hermes keeps talking; background speech does not cut it off, because voice interruption is off.
5. She wants to stop Hermes mid-sentence, so she taps the orb ("Tap to interrupt"), then carries on talking.
6. When she is done she turns "Keep listening" off.

### 3. Amanda continues a conversation on Duo

> [ASSUMPTION] Illustrative flow assembled from confirmed decisions, not a narrated session.

1. Amanda opens the app on Duo; outer Talk is the launch default.
2. She switches to Transcript, starts a recording and sees the transcript remain visible.
3. She opens Duo while the turn is active. **Climax:** recording or reply continues, and the conversation, draft and transcript position stay intact as the layout changes.
4. Fully open, she sees the composer beneath the transcript and the voice controls beside it. She can type without leaving the conversation.
5. She closes Duo; the outer display returns to the last-used Transcript view within this app session.

If the keyboard obstructs the composer or an essential control in laptop posture, content moves or scrolls around its actual position. If the connection is lost, preserve and label safe cached context and offer the existing Connect or Retry path; an unconfirmed turn is not automatically replayed.

## Responsive & Platform

- **macOS:** same orb, status line, Cancel and reply rail. No hands-free pill and no voice-interruption setting (hands-free is iOS-only). Orb supports pointer hover and keyboard activation (Space/Return when focused).
- **Small iPhones / large Dynamic Type:** the voice zone keeps the orb and status line visible; the reply rail compresses first.

### iPhone Duo

The [Duo posture wireframe](.working/flow-duo-postures-2026-11-09.excalidraw) is exploratory; it illustrates these modes and panel concepts, not finalized control placement.

| Context | Confirmed experience | Still open |
|---|---|---|
| Outer display | Full use focused on talking, with orb, status line and Keep listening hands-free control visible in Talk view; typing lives in Transcript view, not Talk view. The minimal header shows profile name, connection status and settings. App launch starts in Talk mode without persisting the prior launch's choice; closing Duo within the app session restores the last-used outer mode. A small toggle nearer the bottom controls in both views switches Talk and Transcript; Transcript-focused keeps the transcript visible during the voice action. | Other Talk controls, exact toggle coordinates and small-action presentation. |
| Fully open inner display | Transcript gets a bit more than half the available space, with the composer beneath it; beside it, the remaining space holds the same voice orb, status line and Keep listening hands-free control as outer Talk view. | Exact proportions. |
| Book posture | Split conversation across panels: transcript on the physical right in LTR and left in RTL; talk controls and composer on the opposite panel. | Transition stability and validation, internal placement. |
| Laptop posture while typing | Transcript and composer together on the top physical panel; system keyboard below is the desired experience. Adapt app content to the keyboard's actual position, keeping the composer and active voice action reachable; transcript history may scroll and secondary controls may move out of view. Preserve focus and fold continuity. | Exact reflow and placement remain open; verify actual keyboard configurations and behavior in Hermes. |

The change into book mode is intended to be discrete, not a continuous interpolation. Use Apple's active fold division and its orientation to enter vertical book-like and horizontal laptop-like arrangements, rather than a custom hinge-angle threshold. Transition behavior and stability still need design and validation. Do not infer posture from width: the simulator has shown the full inner window at partial opening. On a regular iPhone without a hinge, retain the existing voice-first experience.

**System guidance and evidence, not a placement guarantee.** [Apple's Duo guidance](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo) recommends container-based resizing, checking all poses and orientations, and accounting for active fold divisions; system bars may become vertical. [Reserved regions](https://developer.apple.com/documentation/swiftui/reservedregion) provide a view-coordinate frame, including its margins, for active divisions; arrangement views can adapt related content around a fold. These iOS 27.1+ APIs require availability gating; iOS 26 remains supported. The current F11 implementation uses a 600 pt HUD-width breakpoint, which is a size fallback, not a posture signal or an implementation of these posture decisions.

In one **standalone probe**, not Hermes, on the iOS 27.2 Duo simulator held at 117.08° partially open, the window was 669×951 pt. The active horizontal division was `(0, 455.5, 669, 40)` pt, the text field was above it, and the system keyboard's reported screen and window frame was `(0, 455.5, 669, 495.5)` pt: its frame overlaps the entire division. The screenshot shows the keys visually in the lower portion; individual key frames were not measured. Evidence: `/tmp/duo-keyboard-evidence/laptop-measured.png` (temporary, local). [Keyboard frame notifications](https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification) report geometry; this observation does not establish that an app can request or guarantee a panel for the system keyboard, nor does it verify Hermes' layout. Test Hermes and a real device separately.

## Settled after review

- The voice-interruption opt-in lives in the Settings sheet, off by default.
- Tapped recordings use the same 1.5 s silence endpoint as hands-free.
