# Live Home bridge evidence

This is the operator handoff for the narrow iOS Home pilot adapter. It assumes
the Home deployment and its route have already been approved. It does not
replace the full Home pairing/discovery work in `IOS-HOME-01`.

## Before opening the iOS app

The Home operator must have:

1. A reachable tailnet-only Home WSS route at
   `/api/v1/bridge/ws`.
2. The deployed Home route ID. It must match
   `HERMES_HOME_BRIDGE_ROUTE_ID` (the default is `local`).
3. An active Home conversation grant whose opaque `handle`, device identity,
   and `profile_id` match the iOS pilot profile.
4. A pre-issued Device credential for that approved grant.

Keep the Device credential in the secure operator handoff. Do not put it in a
ticket, screenshot, log, shell history, source file, or validation artifact.

## Activate the iOS Home route

1. Build and launch the app without the `-HomeBridgeFake` launch argument.
2. Open **Configure Relay** and choose **Set up live Home bridge**.
3. Enter the approved route, for example
   `wss://<tailnet-home-host>/api/v1/bridge/ws`.
4. Enter the Home route ID, household receipt label, opaque conversation
   handle, and the pre-issued Device credential.
5. Select **Activate Home bridge**.

On a later retry, leave the credential field blank to reuse the active
Keychain credential; entering a new value replaces it.

Activation writes the Device credential to Keychain, stores only the route and
opaque claim metadata in the app-support file, and performs one live
`conversation.open` handshake. Home mode is selected only after the response
is `ready` with the expected route identity and capabilities. A failed
handshake leaves the legacy relay selected so the route can be corrected and
retried.

## Capture STD-4 evidence

After activation, connect again and record the run against the real Home route:

- one text turn;
- one voice/audio turn;
- a confirmed interrupt;
- disconnect and reconnect with no replay of the interrupted turn;
- timing capability absence and audio-failure behaviour;
- the selected Home profile remaining fixed across app resume and reconnect.

For each run, record the build commit, route ID, profile ID, grant handle
reference (not the credential), timestamp, observed result, and any Home-side
logs needed to correlate the turn. Redact household identifiers and all
credentials from the evidence artifact.

This proves the live gate. Simulator/unit tests prove the adapter's local
contracts, but they do not close the live endpoint evidence requirement.
