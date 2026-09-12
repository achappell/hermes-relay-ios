---
title: 'iOS visual design pass'
type: 'design'
created: '2026-09-11'
status: 'approved'
direction: 'Night Console iOS adaptation'
upstream_ux: '~/Documents/Vaults/Personal Vault/projects/hermes-home/sources/ux/ux-hermes-relay-tui-2026-09-07/DESIGN.md'
upstream_experience: '~/Documents/Vaults/Personal Vault/projects/hermes-home/sources/ux/ux-hermes-relay-tui-2026-09-07/EXPERIENCE.md'
icon_mark: 'abstract signal orb'
reviewed_surfaces:
  - conversation idle and no-profile state
  - unavailable and cached-draft state
  - relay configuration and saved profiles
  - household Device discovery
  - voice and hands-free controls
  - Local History
  - app icon and target branding
---

# iOS visual design pass

## Design question

How should the native iOS doorway express Hermes' shared Night Console identity
while remaining recognisably iOS, calm during idle, and explicit about every
connection, capture, response, and recovery state?

## Constraints and settled principles

- Hermes remains the authority for sessions, Profiles, answer content, and
  protocol phases.
- The selected Profile is visible before capture and remains identifiable
  through completion.
- Every meaningful state has readable text. Color, motion, sound, and glass
  are supporting signals, never the only meaning.
- Retry reconnects only. It never silently reopens capture or replays an
  uncertain turn.
- Local History is deliberate and Profile-scoped; no audio, prompts, tokens,
  or raw frames enter the visual design artifacts.
- iOS keeps native navigation, sheets, type scaling, VoiceOver order, and
  touch-target expectations. It does not copy the TUI's geometry literally.

## Current-state diagnosis

The current app is technically coherent but visually split between two
languages:

1. The conversation surface is a bright, spacious white canvas with a large
   grey microphone orb, repeated `Ready`/`Tap to record` cues, and several
   rounded Liquid Glass surfaces.
2. The product UX authority describes a dark Night Console with explicit
   identity, phase, unavailable, recovery, and transcript semantics.
3. The current glass treatment is attractive in isolation but makes every
   surface feel equally important. A disconnected state can therefore still
   look like an idle, ready state.
4. Configuration is a native light Form, but its filled text fields hide the
   meaning of Client ID, Device ID, and Display name until the user already
   understands the model.

The design problem is hierarchy and state language, not a shortage of blur.

## Recommended direction: Night Console iOS adaptation

Use a dark-first, system-adaptive Night Console for the live conversation
surface, with native iOS structure for configuration and history. The app keeps
one visual vocabulary while allowing platform-owned navigation and controls to
remain familiar.

### What this protects

- Cross-surface Hermes identity and state semantics.
- Quiet idle presentation with activity emerging only when a turn is real.
- Clear separation between identity, live phase, response content, and
  recovery action.
- Native iOS accessibility and interaction conventions.
- A coherent app-icon direction that represents a conversation doorway, not
  only a microphone.

### What this gives up

- The current bright white canvas cannot remain the default live surface.
- The app will need a deliberate light adaptation rather than relying on
  unexamined system materials.
- Some existing previews and visual snapshots will need updated fixtures.

## Visual language

### Color roles

Use semantic roles from the canonical Night Console rather than scattering
literal colours through views:

| Role | Direction |
|---|---|
| Base | `#0B101B` midnight canvas |
| Console surface | `#101725` header and bottom control grouping |
| Panel | `#0D1320` transcript, recovery, and setup cards |
| Raised panel | `#182338` selected profile or important context |
| Primary ink | `#EAF7FF` |
| Secondary ink | `#B3C0D2` |
| Live | `#62E6C7` for active/healthy signals |
| Attention | `#FFCF5C` for current phase and pending work |
| Identity | `#7C8CFF` for Profile and interactive focus |
| Unavailable | `#FF7D9C` for transport, permission, and identity failure |

The light adaptation maps these roles to readable system surfaces; it does not
replace semantic roles with arbitrary accent colours. Status text remains
explicit in every appearance.

### Typography

- Use SF Pro for state, action, setup, and response text.
- Use SF Mono sparingly for endpoint metadata, session duration, and compact
  diagnostic labels.
- Make the current state the strongest text on the live surface: `Ready`,
  `Listening`, `Thinking`, `Speaking`, `Complete`, or `Unavailable`.
- Keep technical protocol words secondary to child-readable action language.
- Preserve Dynamic Type; never make the state legible only through the
  visualizer.

### Shape, spacing, and depth

- Adopt a 4/8/12/16/24/32 spacing rhythm.
- Use 12–16pt corners for cards and 20pt only for the outer conversation
  container or a platform-owned sheet.
- Reserve capsules for compact status pills and controls, not every content
  surface.
- Use tonal layering and hairline borders for grouping. Avoid floating every
  card as if it were equally urgent.
- Keep touch targets at least 44pt and preserve visible focus.

## Surface decisions

### 1. Conversation shell

The live doorway has four readable zones in this order:

1. Profile and connection header.
2. Current state and visualizer.
3. Response/transcription rail.
4. One action surface: voice controls plus typed composer.

The header owns connection recovery. The central state owns phase truth. The
bottom surface owns capture and submission. No zone should repeat the same
message in different words.

### 2. Idle and no-profile state

- No Profile: show `No Profile selected` and make `Configure relay` the primary
  action. Replace the microphone instruction with `Configure a relay to begin`.
- Profile selected but disconnected: show the Profile, `Unavailable`, and a
  recovery card with `Retry` and `Edit relay`.
- Connected idle: show `Ready` and make tap-to-speak the dominant action.
- Keep the central visualizer quiet and static when idle; active glow belongs
  to active capture or playback.

### 3. Active voice turn

- Keep the Profile name visible above the current phase.
- Use one large state label plus restrained synchronized motion.
- Show live transcription or response text in one rail; do not make the orb
  compete with readable content.
- Use `Cancel` only while local capture is active and `Interrupt` only while a
  supported response is active. Do not present both as generic stop controls.
- Hands-free mode is a mode switch with an explicit state, not a second
  microphone action.

### 4. Unavailable and recovery

The unavailable surface should visibly stop pretending to be ready:

- state label: `Unavailable`
- explanation: plain-language failure and affected path
- primary action: `Retry`
- secondary action: `Edit relay` or `Open Settings` where applicable
- unresolved turn: preserved, labelled, and never silently replayed

The recovery card is the place for the explanation. Do not bury the only useful
action in a small header button while the centre still advertises capture.

### 5. Typed composer and cached drafts

- Keep the composer available when disconnected so local drafts remain useful.
- Show `Saved locally — connect before sending` as a compact status row.
- Disable the send control with an explanation, not merely reduced opacity.
- Hide prompt-history arrows when there is no history; when present, group them
  under a labelled `Recent prompts` affordance rather than relying on chevrons.
- When the composer is focused, let it own the visual emphasis and reduce the
  voice controls to avoid competing input modes.

### 6. Configuration and profiles

Use the native sheet structure but strengthen its information architecture:

- `Profiles`: active profile, connection status, Add profile, delete action.
- `Household Devices`: approved and discovered Devices, with explicit pending
  and inert states.
- `Relay`: Endpoint, then a labelled `Device identity` group for Client ID,
  Device ID, and Display name.
- `Credentials`: token state, replacement, and removal.

Required fields show their requirement before Save. Errors attach to the field,
focus the first invalid field, and explain the fix. The active/selected marker
must be a checkmark or equivalent; a dotted connection-status icon must not be
asked to mean selection.

### 7. Device discovery and setup

Use the canonical sequence `Discover → Connect → Room → Wake Mappings → Ready`.
The current step is attention-coloured, completed steps are live-coloured, and
locked steps are visibly pending. Discovery is not approval; approval is not
Ready.

Empty and failure states each get one explanation and one labelled next action.
The refresh icon may remain as a secondary affordance, but `Retry discovery`
must be available as text.

### 8. Local History

- Present history as a native sheet with a calm dark or adapted panel surface.
- Keep the newest content at the bottom and make local scope visible in the
  empty state.
- Use role and time metadata as secondary structure; response text remains the
  visual centre.
- Keep Export in a menu. It should not compete with the conversation itself.

## Liquid Glass review

Keep the native iOS 26 APIs, but narrow their job:

- Use `GlassEffectContainer` for the grouped bottom control surface.
- Use interactive glass only for tappable controls.
- Use a consistent 12–16pt shape family for cards and controls; reserve the
  largest radius for the outer container.
- Let the central visualizer sit on the Night Console canvas rather than inside
  another glass card.
- Do not apply glass to every explanatory or error panel. Recovery and setup
  need contrast and structural borders more than optical softness.
- Keep the existing availability fallback for earlier OS versions.
- Add morphing glass transitions only when a control genuinely changes between
  compact and expanded states; do not animate state truth for decoration.

## Accessibility and motion

- VoiceOver order: Profile → current state → response/transcription → primary
  action → secondary actions.
- Pair every color and icon with readable text.
- Use `prefersReducedMotion` to freeze the visualizer and remove looping
  transitions while retaining the state label.
- Announce state transitions once, not every audio or transcription frame.
- Keep unavailable and pending states distinguishable without colour.
- Verify Dynamic Type at large accessibility sizes in the configuration form,
  recovery cards, and composer.

## App icon brief

Recommended direction: a **Hermes signal orb**, not a literal microphone. The
orb represents typed and voice conversation, relay identity, and the shared
Night Console visualizer without implying that iOS is only a recorder.

- Background: Night Console midnight `#0B101B`.
- Mark: three restrained relay rings with a central identity spark or abstract
  `H` junction.
- Accent: identity violet `#7C8CFF` with a small live teal `#62E6C7` highlight.
- No text, no tiny waveform detail, no generic chat bubble.
- The silhouette must remain recognisable at small Home Screen sizes and in
  monochrome/tinted rendering.
- Final deliverable includes the required iOS variants, asset-catalog wiring,
  and an installed simulator/archive check.

## Alternatives considered

### Full bright Liquid Glass

Lowest implementation cost and familiar in daylight, but it conflicts with the
canonical dark Night Console and makes failure/idle states too visually alike.
Rejected as the primary direction.

### Full TUI replica on iOS

Strong cross-surface brand consistency, but it would make iOS feel like a
terminal in a sheet and would overrule native navigation, form, and type
expectations. Rejected.

### Night Console iOS adaptation — recommended

Dark-first semantic identity on the conversation surface, native iOS structure
for setup/history, restrained Liquid Glass for floating controls, and a real
light adaptation for system appearance. This keeps the relationship coherent
without turning the phone into a miniature appliance panel.

## Implementation sequence after direction approval

1. Introduce semantic visual tokens and appearance previews.
2. Fix the state hierarchy: no-profile, disconnected, unavailable, and ready.
3. Reconcile active-profile deletion with the live conversation store.
4. Recompose configuration and Device setup around labelled steps and field
   errors.
5. Refine composer/history/voice controls and reduced-motion behavior.
6. Create and wire the signal-orb app icon set; the approved master, light,
   dark, and tinted renditions are now wired into the target and verified
   through simulator installation and App Store Connect-style export.
7. Validate light/dark appearance, Dynamic Type, VoiceOver order, simulator
   screenshots, and the existing focused XCTest suite.

## Decision recorded

Amanda approved the recommended abstract signal-orb mark on 2026-09-11. The
icon should represent typed and voice conversation, relay identity, and the
shared Night Console visualizer without implying that iOS is only a recorder.

The approved direction is now implemented in production UI. Semantic adaptive
tokens and color assets drive the conversation canvas, doorway state hierarchy,
transcript/recovery panels, voice and hands-free controls, configuration, and
Device setup. Liquid Glass remains limited to grouped and interactive control
surfaces, with structural panel fallbacks everywhere explanatory content needs
stable contrast. The approved 1024px signal-orb master and appearance variants
remain implemented in the app's asset catalog and target wiring.

## Visual implementation verification

- iOS simulator build succeeds with no build warnings.
- The full iOS simulator XCTest suite passes 320/320.
- Light and dark iPhone 17 Pro simulator screenshots were reviewed for the
  no-profile doorway, recovery card, canvas contrast, and composer hierarchy.
- Reduced-motion behavior remains covered by the existing paused visualizer and
  transcript reveal logic.
- The macOS target compiles with signing disabled; a signed macOS build still
  requires a local Mac Development certificate/private key.

## Branding verification recorded

- `AppIcon.appiconset` contains the default/light, dark, and tinted 1024px
  renditions.
- The iOS simulator build succeeds; the current `com.achappell.HermesRelay`
  installation shows the signal orb on the Home Screen.
- `xcodebuild archive` succeeds for the generic iOS device destination.
- `xcodebuild -exportArchive` succeeds with the App Store Connect export
  path (using Xcode's `app-store` alias, which reports as
  `app-store-connect`); the exported arm64 IPA contains `Assets.car`, the
  three AppIcon renditions, an Apple Distribution signature, and a store
  provisioning profile with beta reporting enabled.
- The full iOS XCTest suite passes 320/320 after one aggregate timing failure
  rerun passed for the pre-existing simulator-audio scheduling test.
