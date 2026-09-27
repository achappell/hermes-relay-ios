---
name: Hermes Relay
status: final
scope: voice controls (central voice orb, status line, hands-free pill, reply rail, bottom bar)
sources:
  - _bmad-output/implementation-artifacts/ios-visual-design-pass.md
  - docs/superpowers/specs/2026-08-30-ios-voice-interface-design.md
  - docs/plans/2026-09-09-ios-16-hands-free-barge-in.md
  - _bmad-output/implementation-artifacts/spec-2-1-ios-capture-acknowledgement-and-live-transcription.md
  - _bmad-output/implementation-artifacts/spec-1-2-render-honest-ios-turn-phases.md
  - _bmad-output/implementation-artifacts/spec-2-2-ios-disconnected-state.md
  - docs/plans/2026-08-30-ios-voice-interface-testing-plan.md
updated: 2026-09-27
---

# Hermes Relay — Experience Spine (voice controls)

> Scope: how voice works on the conversation screen. Paired with [DESIGN.md](DESIGN.md); tokens are referenced as `{path.to.token}`. The spines win on conflict with mocks, earlier specs and the sources above. Decisions and their reasons are in `.memlog.md`.

## Foundation

- **Form factor:** iPhone first; the same conversation screen on macOS. Hands-free is iOS-only (as today).
- **UI system:** native SwiftUI on iOS 26 / macOS 26, the Night Console tokens in DESIGN.md, and Liquid Glass limited to the typing surface and small controls.
- **Stakes:** polished enough to show people. A first-time user who taps the big orb must be able to talk without instruction.
- **Purpose of the screen:** voice-focused conversation. Voice is primary; typing is secondary.

## Information Architecture

One screen, four zones (see DESIGN.md Layout):

| Zone | Owns | Does not own |
|---|---|---|
| Header | Profile, conversation title, connection and recovery | Voice actions |
| Voice | Starting, sending, cancelling and interrupting speech; hands-free | Typed input |
| Reply rail | The latest exchange, in step with speech | Controls |
| Typing | Recent prompts, composer, send | Voice capture |

This supersedes the 2026-09-11 rule that the bottom surface owns capture: voice now lives with the orb.

## Voice and Tone

Plain, short, action-first. The status line always reads "State · Action".

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

- The only talk control on the screen. Tapping it performs the action its glyph shows.
- Tappable only when connected and not in a state where a tap is blocked (hands-free waiting or hearing you, or an action already in flight that is not an interrupt).
- The bottom-bar microphone button and its "Tap to record" label are removed.

### Status line and Cancel

- Status line directly under the orb. Cancel appears under it only while a tapped recording is listening; it discards without sending.

### Hands-free pill ("Keep listening")

- A small pill under the status line; tapping it toggles. Off is outlined, on is filled, and the status line then reads "Listening for speech". Accessibility: a toggle button, label "Keep listening", value On/Off, hint as in Voice and Tone.
- Arms conversation mode: listen, send on a pause, answer, listen again.
- Never armed automatically (not at launch, on connect, or after a reply). Disarms when the app leaves the foreground or the connection drops (as today).

### Recent prompts

- One small clock button left of the composer, only when there is history (replaces the ▲▼ arrows).
- Tapping it opens a native menu titled "Recent prompts": up to 8 of your recent typed prompts, newest first, each on one line (truncated). Choosing one puts it in the composer, focused, to edit or send; it never sends by itself.
- Typed prompts only, in memory only (never saved), cleared when the active Profile changes.
- Accessibility: button label "Recent prompts"; each menu item reads the prompt text.

### Reply rail

- While you talk: your live words (required by story 2.1).
- While Hermes is thinking: no reply text, only the status line.
- While Hermes speaks: its reply appears in step with the audio, word by word where speech timing exists, sentence by sentence otherwise. The full text is in History.

## State Patterns

Visual reference: [key-conversation.html](mockups/key-conversation.html). The spine wins on conflict.


| State | Orb | Tap does | Rail | Hands-free pill |
|---|---|---|---|---|
| Idle | mic, still | Start listening | Last exchange | Enabled |
| Listening (tap) | stop, live | Send now | Your live words | Enabled (turning on cancels nothing) |
| Transcribing | stop | Send now | Your words | Enabled |
| Thinking | hand, attention | Interrupt, then listen | No reply text | Enabled |
| Buffering / Speaking | hand, attention | Interrupt, then listen | Reply in step with audio | Enabled |
| Hands-free waiting | ear | Nothing (disabled) | Last exchange | On |
| Hands-free hearing you | waveform | Nothing (disabled) | Your live words | On |
| Hands-free, Hermes replying | hand | Interrupt (stays in hands-free) | Reply in step with audio | On |
| Not connected | connection glyph | Nothing (not a button) | Cached exchange, labelled | Hidden |

## Interaction Primitives

- **Tap to talk, pause to send.** A tapped recording ends on its own after about 1.5 s of quiet (the existing hands-free silence endpoint, which tolerates a 1 s conversational pause) and sends. Tap the orb to send early; Cancel to discard.
- **Tap to interrupt.** During a reply, tapping the orb interrupts; outside hands-free it then starts listening.
- **Voice interruption is opt-in.** Off by default. When on, speaking during a reply interrupts only on echo-safe headphone routes (wired, Bluetooth HFP/LE); on the built-in speaker, interrupting stays tap-only.
- **Keyboard.** Focusing the composer lets typing own the screen; the voice zone scrolls. Talking is always one tap on the orb once the keyboard is down.

## Accessibility Floor

- The orb is one button: label "Voice", value = current state, hint = what a tap does (e.g. "Starts listening.").
- VoiceOver order: Profile → state (orb) → Cancel / hands-free pill → reply rail → typing.
- Announce state changes once, not every recognition or audio frame.
- Reduced motion freezes the orb rings and glyph pulse; the status line still carries state.
- Hit targets: orb 260 pt, Cancel and the hands-free pill at least 44 pt (the pill's hit area extends beyond its 30 pt height).
- Every state is readable without colour.

## Key Flows

> [ASSUMPTION] Drafted from recorded observations, not from a narrated session (Amanda chose not to narrate one). For review.

### 1. Jensen asks a quick question

1. Jensen opens the app. The screen says "Ready · Tap to talk" under a big microphone orb.
2. She taps the orb, as she always tried to. It turns live and the status reads "Listening · Tap to send".
3. She asks her question; her words appear in the rail as she speaks.
4. She stops talking. **Climax:** without another tap, Hermes takes it: "Thinking · Tap to interrupt".
5. Hermes answers aloud; the words appear in step with the voice.
6. The orb returns to "Ready · Tap to talk".

### 2. Amanda talks hands-free while cooking

1. Amanda turns on "Keep listening" under the orb. The status reads "Listening for speech".
2. She speaks, pauses; Hermes answers aloud.
3. Hermes finishes and the app listens again without a touch.
4. The TV is on in the background. **Climax:** Hermes keeps talking; background speech does not cut it off, because voice interruption is off.
5. She wants to stop Hermes mid-sentence, so she taps the orb ("Tap to interrupt"), then carries on talking.
6. When she is done she turns "Keep listening" off.

## Responsive & Platform

- **macOS:** same orb, status line, Cancel and reply rail. No hands-free pill and no voice-interruption setting (hands-free is iOS-only). Orb supports pointer hover and keyboard activation (Space/Return when focused).
- **Small iPhones / large Dynamic Type:** the voice zone keeps the orb and status line visible; the reply rail compresses first.

## Settled after review

- The voice-interruption opt-in lives in the Settings sheet, off by default.
- Tapped recordings use the same 1.5 s silence endpoint as hands-free.
