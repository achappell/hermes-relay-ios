# IOS-01 Foundation Implementation Plan

> **For Gemini:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a separate native SwiftUI iOS repository that gives the user a runnable conversation shell and a safe, testable seam for the Hermes voice-session protocol.

**Architecture:** Keep SwiftUI presentation and main-actor conversation state above a typed `HermesSessionClient` protocol. Start with an explicit unavailable client so the app can be launched and tested without pretending that live relay support exists; add the WebSocket transport, secure profiles, and audio as separate vertical slices.

**Tech Stack:** Swift 6.3, Xcode 26.6, SwiftUI, Observation, XCTest, iOS 26 and macOS 26 targets.

---

### Task 1: Create the independent repository shell

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `AGENTS.md`
- Create: `docs/architecture.md`
- Create: `docs/workflow.md`

**Steps:**

1. Initialize a sibling Git repository named `hermes-relay-ios`.
2. Document the separate-repository boundary, supported toolchain, current protocol facts, security rules, and validation commands.
3. Keep live credentials, audio captures, Xcode state, and generated build output ignored.
4. Review the documentation for stale terminal-only assumptions or invented relay operations.

### Task 2: Add the runnable SwiftUI foundation

**Files:**
- Create: `HermesRelayIOS.xcodeproj/project.pbxproj`
- Create: `HermesRelayIOS.xcodeproj/xcshareddata/xcschemes/HermesRelayIOS.xcscheme`
- Create: `HermesRelayIOS/HermesRelayIOSApp.swift`
- Create: `HermesRelayIOS/Models/SessionModels.swift`
- Create: `HermesRelayIOS/Services/HermesSessionClient.swift`
- Create: `HermesRelayIOS/ViewModels/ConversationStore.swift`
- Create: `HermesRelayIOS/Views/ContentView.swift`
- Create: `HermesRelayIOS/Views/MessageBubble.swift`

**Steps:**

1. Define typed connection, transcript, session metadata, and normalized Hermes event values.
2. Define the async client protocol around connect, turn streaming, and disconnect.
3. Implement an unavailable client that returns an explicit local error instead of claiming connection.
4. Build the shell with connection state, transcript rendering, composer input, and a connect action.
5. Keep the store on the main actor and leave raw JSON/WebSocket parsing out of the UI layer.

### Task 3: Cover the foundation boundary

**Files:**
- Create: `HermesRelayIOSTests/HermesRelayIOSTests.swift`

**Steps:**

1. Test that the unavailable client explains the missing relay wiring.
2. Test that an unavailable store keeps the draft instead of silently dropping it.
3. Test connection-state labels and transcript-role values.
4. Run the focused XCTest target.
5. Run the iOS simulator and macOS build commands from `README.md`.

### Task 4: Finish the slice

**Steps:**

1. Run the manual plan in `docs/plans/2026-08-30-ios-01-foundation-testing-plan.md`.
2. Record test, build, and manual evidence on IOS-01.
3. Move IOS-01 to `Verify`, then `Done` only after validation and merge.
4. Commit the coherent foundation slice.

### Follow-up slices

- `IOS-02`: Keychain-backed profile/token setup and explicit configuration state.
- `IOS-03`: WebSocket hello/hello_ack and one typed text turn with streamed events.
- `VOICE-04`: Push-to-talk microphone capture and local transcription.
- `VOICE-05`: Signed PCM playback and WAV fallback.
- `VOICE-06`: Voice lifecycle coordination and status surface.
- `IOS-07`: Recovery and local conversation continuity.
- `SESSION-01`: Session browser and transcript hydration after relay support exists.
