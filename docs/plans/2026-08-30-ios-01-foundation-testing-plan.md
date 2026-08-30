# IOS-01 Foundation Manual Smoke Test

This plan validates the first repository slice on the intentional iOS 26 and
macOS 26 targets without a live Hermes endpoint.

## Setup

1. Open `HermesRelayIOS.xcodeproj` in Xcode.
2. Select the `HermesRelayIOS` scheme.
3. Build and run once on an iPhone simulator.
4. Build and run once on `My Mac`.

## Checks

1. On each target, confirm the app launches with the title `Hermes Relay`.
2. On each target, confirm the empty state says the conversation shell is ready and does not
   claim a live connection.
3. On each target, tap `Connect`.
4. On each target, confirm the connection indicator changes to a failed/unavailable state with
   wording that the relay client is not wired yet.
5. On each target, type a draft message.
6. On each target, confirm the draft remains in the composer when the relay is unavailable.
7. Confirm no token, prompt, response, or audio data appears in the Xcode
   console from this flow.

## Exit criteria

- The app is launchable without credentials.
- The iOS Simulator and macOS targets both launch the shell.
- Unavailable transport behavior is explicit and recoverable.
- The composer does not silently discard a draft.
- Unit tests and simulator build/test commands pass.
