# Accessibility Review — iPhone Duo and Regular iPhone

## Verdict

The current draft now explicitly exposes the pending Keep listening state, lets a second activation cancel that request, and represents the armed-but-not-monitoring state during a successful reply. It also includes the selected full-response behavior, state announcements, mode-switch focus fallback, a large-text operability floor, and a keyboard-obstruction fallback. Remaining concerns are specification gaps or validation needs, not observed Hermes defects. This is a document-only review; no app, device, VoiceOver, Dynamic Type, or keyboard validation was run.

## Findings

### Medium — Pending-state accessibility hint does not describe the cancel action

**Evidence:** During tapped capture, the control exposes the value `Pending`; another activation cancels the request (EXPERIENCE.md:107, 132–133, 149). The accessibility hint still points to the generic “Talk, pause, and Hermes answers. Tap the orb to interrupt.” text (EXPERIENCE.md:70, 107), and the general rule only requires a hint describing activation (line 95).

**Impact:** A screen-reader user can hear that the request is pending but is not told that activating the control again cancels it. The visible `Keep listening · Pending` text does not itself establish the toggle's spoken action.

**Objective fix:** Provide a state-specific accessible hint/action for Pending, such as an explicit cancel-request instruction, while retaining the Keep listening label and Pending value. Ensure the transition to On/Off is announced once under the existing state-change rule (line 164).

### Medium — Complete action and post-Complete transition remain unspecified

**Evidence:** Ordinary non-hands-free replies settle in Complete; the phase is stable until the next local capture or send. Exact Complete copy/action, post-Complete action and outer Transcript action at Complete remain open (EXPERIENCE.md:95, 141–142; flow 1, line 187).

**Impact:** The primary control's accessible label, value, hint and available action cannot be specified for this stable state without selecting a behavior. The user-approved no-Complete presentation for armed hands-free replies is clear and is not implicated.

**Objective fix:** Use Story 1.2's stable-until-next-capture/send contract as the baseline and resolve the action/label/value/hint in both voice modes. Keep the approved direct return to listening after a hands-free reply.

**Decision boundary:** This is an explicit owner-open behavior, not a contradiction and not an accessibility defect observed in the application; it blocks a fully specified Complete interaction.

### Medium — Full-response reveal is selected, but mid-reply and paused-reading behavior is open

**Evidence:** A person who cannot hear the reply can select in Settings to see the complete response as soon as available; selection must be accessible (EXPERIENCE.md:122). Accessibility requires discoverable, non-disruptive completed text and preserves user-controlled follow/pause (line 171). The interaction of a setting change mid-reply, paused follow state, reveal and scroll is explicitly open (line 174).

**Impact:** A reader may not know how the rail behaves when switching reveal preference mid-reply or when pausing follow, risking lost reading position or disruption.

**Objective fix:** Decide the interaction between the selected reveal mode, mid-reply changes, follow/pause and scroll while retaining stable focus and access to complete text.

**Decision boundary:** The selection mechanism and full-response choice are confirmed; only these timing/scroll interactions remain open.

### Medium — Outer Transcript traversal and non-mode focus-loss destinations remain open

**Evidence:** When a Talk/Transcript switch removes VoiceOver focus, focus moves to the mode toggle and the new view is announced; equivalent focus is retained across mode/fold changes where possible (EXPERIENCE.md:163, 169). The complete outer Transcript traversal order and other focus-loss destinations remain open (lines 163, 169–170).

**Impact:** The key mode-switch fallback is specified, but a complete VoiceOver/hardware-keyboard sequence and behavior when other controls disappear cannot yet be validated consistently.

**Objective fix:** Specify logical traversal for each mode and remaining focus-loss destinations, without disturbing the approved focus-to-toggle fallback or active turn.

**Decision boundary:** The particular mode-switch fallback is decided; the remaining traversal/focus design is intentionally open.

### Medium — Large-text and keyboard reachability require implementation validation; compact reflow remains open

**Evidence:** At larger Dynamic Type sizes, the active talk/Cancel/Interrupt action remains visible, both early send and discard must be reachable, and the Duo laptop fallback moves or scrolls around actual keyboard obstruction (EXPERIENCE.md:168, 172–175, 224). The exact compact/reflow presentation is open. The standalone probe is not Hermes/device validation (lines 228–230).

**Impact:** A textual reachability rule cannot prove that the required action remains visible and operable across outer, fully open, book, laptop and regular-phone layouts at large text sizes, with keyboard up and down.

**Objective fix:** Validate hit targets, clipping, early-send/discard reachability, focus and keyboard overlap at supported Dynamic Type sizes and relevant Duo postures/input configurations. Resolve compact reflow only where needed to meet the stated floor.

**Decision boundary:** Reachability is a confirmed requirement; exact compact reflow is expressly open. Validation is still needed and is not claimed here.

### Medium — Fold transition stability and accessibility-safe fallback need validation

**Evidence:** Preserve focus, active capture/reply and state across healthy foreground fold/resize, while actual backgrounding or connection loss disarms hands-free (EXPERIENCE.md:50, 109, 157–159, 226–228). Transition stability remains open; iOS 27.1+ fold APIs require availability gating, while the current 600 pt width fallback is not a posture signal (line 228).

**Impact:** Posture changes or unavailable/unstable geometry can move controls or focus, but the approved design has not been verified in Hermes across those states.

**Objective fix:** Validate fold/unfold and fallback transitions with active tapped and hands-free capture, reply playback, VoiceOver, hardware keyboard and large text. Keep the existing distinction between a healthy foreground layout change and actual lifecycle/connection loss.

**Decision boundary:** The system active fold division and orientation are approved; transition stability and validation remain open. Do not infer a different posture behavior from width.

## Resolved in this refresh

- The reply reveal choice for someone who cannot hear audio is explicitly available in Settings, with accessible selection (EXPERIENCE.md:122, 171); this supersedes the prior review's broad unresolved-reveal concern.
- Focus fallback on an outer Talk/Transcript switch is explicitly the mode toggle plus announcement (EXPERIENCE.md:169); traversal elsewhere remains open.
- Pending, On and Off states are now represented in the accessibility value, with pending cancellation specified (EXPERIENCE.md:107, 132–133, 149). The remaining finding is the state-specific spoken hint, not absence of pending semantics.
- Empty capture never submits an empty turn; with a pending request it arms and monitors immediately; cancellation/disconnect clear that request; successful submission arms but waits for the reply (EXPERIENCE.md:147–150). No conflicting accessibility state rule was found.

## Scope and evidence

Reviewed current EXPERIENCE.md and DESIGN.md, latest `.memlog.md`, and cited source requirements for capture/no-speech, Complete/audio failure, disconnected recovery, hands-free permission/lifecycle, and Duo keyboard/layout validation. Source documents confirm pending connection-loss disarming and actionable permission failure requirements. No application code, build, device, VoiceOver, Dynamic Type, keyboard, or visual-render validation was performed.