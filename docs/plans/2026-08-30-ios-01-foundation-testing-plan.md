# IOS-01 Foundation Manual Smoke Test

This plan validates the first repository slice without a live Hermes endpoint.

## Setup

1. Open `HermesRelayIOS.xcodeproj` in Xcode.
2. Select an iPhone simulator and the `HermesRelayIOS` scheme.
3. Build and run.

## Checks

1. Confirm the app launches with the title `Hermes Relay`.
2. Confirm the empty state says the conversation shell is ready and does not
   claim a live connection.
3. Tap `Connect`.
4. Confirm the connection indicator changes to a failed/unavailable state with
   wording that the relay client is not wired yet.
5. Type a draft message.
6. Confirm the draft remains in the composer when the relay is unavailable.
7. Confirm no token, prompt, response, or audio data appears in the Xcode
   console from this flow.

## Exit criteria

- The app is launchable without credentials.
- Unavailable transport behavior is explicit and recoverable.
- The composer does not silently discard a draft.
- Unit tests and simulator build/test commands pass.
