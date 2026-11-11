---
name: Hermes Relay
description: Voice-first conversation doorway to Hermes on iOS and macOS. Night Console identity; calm at rest, explicit in every state. This spine covers conversation voice controls and the iPhone Duo layout direction.
status: draft
scope: conversation voice controls and iPhone Duo posture layouts
updated: 2026-11-09
colors:
  canvas: '#F5F7FB'
  canvas-dark: '#0B101B'
  console-surface: '#FFFFFF'
  console-surface-dark: '#101725'
  panel: '#F0F3F8'
  panel-dark: '#0D1320'
  raised-panel: '#E6ECF5'
  raised-panel-dark: '#182338'
  ink-primary: '#0B101B'
  ink-primary-dark: '#EAF7FF'
  ink-secondary: '#526176'
  ink-secondary-dark: '#B3C0D2'
  live: '#087A4A'
  live-dark: '#62E6C7'
  attention: '#8C6300'
  attention-dark: '#FFCF5C'
  identity: '#4C59D9'
  identity-dark: '#7C8CFF'
  on-identity: '#FFFFFF'
  on-identity-dark: '#0B101B'
  unavailable: '#BE3455'
  unavailable-dark: '#FF7D9C'
typography:
  state:
    family: SF Pro
    style: headline
    weight: semibold
  action-hint:
    family: SF Pro
    style: headline
    weight: regular
  body:
    family: SF Pro
    style: body
  caption:
    family: SF Pro
    style: caption
  metadata:
    family: SF Mono
    style: caption
rounded:
  card: 16
  control: 12
  outer: 20
  pill: 999
spacing:
  xs: 4
  sm: 8
  md: 12
  lg: 16
  xl: 24
  xxl: 32
components:
  voice-orb:
    diameter: 260
    core-diameter: 142
    glyph-size: 34
    press-scale: 0.94
    min-hit-target: 260
  status-line:
    typography: '{typography.state}'
    action-typography: '{typography.action-hint}'
  hands-free-pill:
    height: 30
    min-hit-target: 44
    glyph: arrow.triangle.2.circlepath
    rounded: '{rounded.pill}'
    off-border: '{colors.ink-secondary}'
    off-ink: '{colors.ink-secondary}'
    on-fill: '{colors.identity}'
    on-ink: '{colors.on-identity}'
    on-ink-dark: '{colors.on-identity-dark}'
    typography: '{typography.caption}'
  recent-prompts-button:
    diameter: 32
    min-hit-target: 44
    glyph: clock.arrow.circlepath
    ink: '{colors.ink-secondary}'
  cancel-link:
    min-hit-target: 44
    typography: '{typography.caption}'
  reply-rail:
    background: '{colors.panel}'
    rounded: '{rounded.card}'
---

# Hermes Relay — Design Spine (conversation)

> Scope: conversation voice controls and the iPhone Duo layout direction. The Night Console direction approved on 2026-09-11 (`_bmad-output/implementation-artifacts/ios-visual-design-pass.md`) remains the visual identity for everything else; this spine refines it for voice and supersedes one rule there (capture moves from the bottom surface to the orb). Tokens mirror the shipped asset catalog (`Hermes*` color sets); the spine wins on conflict with any mock.

## Brand & Style

Hermes is a conversation you speak to, not a recorder. The live screen is calm at rest and explicit when something is happening. The central orb is the one place you touch to talk; everything around it explains state in plain words. It should feel polished enough to hand to someone who has never seen it: the first thing they try (tapping the big orb) works.

## Colors

Semantic roles only; never literal colors in views. Each role has a light and dark value (`{colors.canvas}` / `{colors.canvas-dark}` and so on).

- `live` — listening and healthy activity.
- `attention` — the current phase while Hermes works (thinking, speaking).
- `identity` — the Profile and interactive focus; hands-free when on.
- `unavailable` — connection, permission and identity failure.
- `ink-primary` for state words; `ink-secondary` for supporting text.

Color is never the only signal: every state has text in the status line.

## Typography

SF Pro throughout, with Dynamic Type. When a tap action is available, the status line has two parts: the state (`{typography.state}`, strongest text on the screen) and the tap action (`{typography.action-hint}`), separated by " · ". Hands-free waiting/hearing and disconnected states show state alone. SF Mono only for metadata (session duration, endpoint).

## Layout & Spacing

The regular conversation screen has four zones, top to bottom; Duo's outer Transcript view is an explicit exception combining transcript, typing and its small voice action:

1. **Header** — Profile, conversation title, connection.
2. **Voice** — the voice orb, the status line under it, then Cancel (only while listening) and the hands-free pill.
3. **Reply rail** — the latest exchange.
4. **Typing** — Recent prompts button, composer, send.

On a regular iPhone without a hinge, the voice zone is vertically centred when there is room; with the keyboard up it scrolls away and the typing zone stays above the keyboard. Spacing uses the named `spacing` scale (4/8/12/16/24/32 pt).

On iPhone Duo, use the same identity and tokens. Outer Talk and Transcript-focused modes are distinct; the latter includes a small start-talking action, but not the full Talk-mode content. On the fully open inner display, the transcript has a little more than half the available space, with the composer beneath it; beside it, the remaining space holds the same voice orb, status line and Keep listening control as outer Talk view. Exact proportions remain open. In book posture, place transcript on the physical right in LTR and physical left in RTL, with talk controls and composer on the opposite panel. While typing in laptop posture, transcript and composer belong on the top physical panel; a system keyboard below is the desired experience, not an app-controlled or guaranteed placement. If the actual keyboard obstructs the composer or an essential control, move or scroll app content around it so the composer and active voice action remain reachable. Other laptop control placement remains open. Respect system safe areas and active fold divisions; do not place important interactive content across a fold.

Start in Talk mode on app launch; do not persist the outer-mode choice across launches. Within an app session, closing Duo restores the last-used outer mode.

Both outer views show a small Talk/Transcript toggle nearer the bottom controls, with a minimum 44 pt hit target and a clear selected state. Exact coordinates and visual treatment remain open.

If an outer-mode switch removes the VoiceOver-focused control, focus moves to this toggle and the new view is announced. This does not change focus behavior for fold or resize when the control remains.

The outer Talk view includes the orb, status line and visible Keep listening hands-free control. Outer-display typing belongs in Transcript view, not Talk view. Other controls and exact presentation remain undecided; this does not remove any other control.

The outer header is minimal: profile name, connection status and a settings button. Exact visual treatment remains exploratory.

Switching outer views must not interrupt an active recording or reply. Keep the state-appropriate voice controls available and retain the transcript and draft across the switch.

[Duo posture wireframes](.working/flow-duo-postures-2026-11-09.excalidraw) explore the layouts; the spines win on conflict. The approved direction uses the system-provided active fold division and its orientation for book/laptop arrangements, rather than a custom angle threshold. Transition stability and validation, exact proportions and unlabelled placements remain open.

## Elevation & Depth

The orb sits directly on the canvas, not inside a card. The reply rail is a flat panel (`{colors.panel}`, hairline border). Liquid Glass is reserved for the grouped typing surface. The hands-free pill is a plain outlined or filled capsule, not glass. No glass on the orb.

## Shapes

Cards `{rounded.card}`, controls `{rounded.control}`, the outer typing container `{rounded.outer}`, status pills `{rounded.pill}`. The orb is a circle; the hands-free pill is a capsule.

## Components

Visual reference: [key-conversation.html](mockups/key-conversation.html) (ready, listening, speaking, hands-free, light). The spine wins on conflict.


### Voice orb (`{components.voice-orb}`)

A 260 pt tappable circle: three quiet rings and a coloured core with a single action glyph. Use `{colors.on-identity}` on the light phase cores and `{colors.on-identity-dark}` on the dark phase cores. Against live, attention and identity respectively, the calculated contrast ratios are 5.39:1, 5.38:1 and 5.62:1 in light appearance, and 12.37:1, 12.98:1 and 6.39:1 in dark appearance. These opaque combinations exceed the 3:1 non-text contrast floor for meaningful action glyphs; verify rendered states as well. The glyph shows **what a tap will do**, not the state:

| Tap will | Glyph |
|---|---|
| Start talking | `mic.fill` |
| Send now (while listening) | `stop.fill` |
| Interrupt Hermes | `hand.raised.fill` |
| (hands-free waiting) | `ear` — not tappable |
| (hands-free hearing you) | `waveform` — not tappable |

Core and ring colour follow the phase role (`live` listening, `attention` thinking/speaking, `identity` ready). Pressed: scales to `{components.voice-orb.press-scale}`. Disabled: rings still, glyph at reduced opacity. When not connected, the orb shows the connection glyph (configure, reconnecting, unavailable) and is not a button.

### Outer Transcript-focused voice action

A small state-dependent action sits with the transcript, not the full Talk-mode surface. Indicate the current action using the same start, send and interrupt glyph semantics as the orb. A separate Cancel action appears during tapped recording. Each has a hit target of at least 44 pt; state and action remain legible without relying on color. Exact placement and visual treatment remain open.

While hands-free is armed, outer Transcript view also shows a small Keep listening control indicating the armed state and allowing disarm without a view switch. Its appearance when disarmed remains open.

### Status line (`{components.status-line}`)

"State · Action", e.g. "Ready · Tap to talk", "Listening · Tap to send", "Speaking · Tap to interrupt". Hands-free waiting/hearing and disconnected states show the state alone.

### Cancel link (`{components.cancel-link}`)

A small text button under the status line, only while a tapped recording is listening. Label "Cancel".

### Hands-free pill (`{components.hands-free-pill}`)

A small capsule under the status line: loop glyph + "Keep listening". It is deliberately quieter than the orb and status line. Off: hairline outline, `{colors.ink-secondary}` text and glyph. On: filled `{colors.identity}` with `on-identity` text and glyph (white in light, `{colors.canvas-dark}` in dark, so the label stays above 4.5:1). No caption. iOS only.

When Keep listening is requested during a tapped recording, show "Keep listening · Pending"; tapping it again cancels the request. Arm it as soon as that recording ends. If recognized speech is submitted successfully, show "Keep listening · On" while Hermes replies: it is armed but waits until the reply finishes before monitoring speech. If capture ends with no recognized speech, submit no empty turn; arm Keep listening and start monitoring immediately. If the recording is cancelled or the connection drops, clear the pending request and do not arm. Existing echo-safe barge-in rules remain; this handoff does not monitor speech during a successful reply. After an armed hands-free reply, the status goes directly back to listening rather than briefly showing Complete. These are desired UX changes.

### Recent prompts button (`{components.recent-prompts-button}`)

A single small circular button left of the composer with a clock glyph, in `{colors.ink-secondary}`. It replaces the two ▲▼ arrows and appears only when there is history. It opens a native menu of recent prompts.

### Reply rail (`{components.reply-rail}`)

The last few turns. Normally Hermes's reply appears in step with its voice; a person who cannot hear the reply audio can explicitly select in Settings to show the complete response as soon as available. The selection must be accessible; storage scope and automatic detection remain open. Your words appear live while you talk.

## Do's and Don'ts

- **Do** make the orb the talk control in the regular voice screen; Duo's outer Transcript-focused mode has a small start-talking action as an explicit exception.
- **Do** show state and action in words whenever an action is available; hands-free waiting/hearing and disconnected states use state alone.
- **Don't** add a duplicate microphone action to the regular voice screen or the full Talk-mode content to outer Transcript-focused mode.
- **Don't** use bare ▲▼ chevrons for prompt history; one labelled Recent prompts button.
- **Don't** let the hands-free control compete with the orb: a small pill, never a full switch row with a caption.
- **Don't** stream Hermes's text before it speaks in the normal speech-synchronized experience; the complete-response accessibility behavior is the explicit exception.
- **Don't** animate the orb when idle; activity is for real activity. Reduced motion freezes it.
- **Don't** use a microphone glyph when a tap would do something else.
