# IOS-34 remote close validation

## Evidence and scope

The original device incident has not been reproduced on hardware. Before the
change, real loopback closes 1000, 1001, and 1008 all surfaced as `NSURLError`
through Foundation's receive callback on macOS 26.6.2. Do not describe the
issue's proposed clean-close mechanism as a confirmed root cause.

A deterministic regression did confirm that an unexpected `CancellationError`
silently abandoned the reader without failing the turn or notifying recovery.
That regression failed before the fix and passes after it.

The connection now listens to Foundation's native close and task-completion
notifications as well as receive callbacks. A locked terminal state finishes
pending reads once, rejects subsequent operations, and ignores late callbacks.
The reader also distinguishes local task cancellation from transport cancellation
and discards frames returned by an obsolete connection generation.

UX expectation: leave Thinking with the existing connection-closed error,
preserve partial text and the unconfirmed prompt, and use the existing bounded
reconnect ladder. Reconnecting must never replay the prompt automatically.

## Automated validation — 2026-09-07

- Focused macOS transport XCTest: **19 passed**.
- Full iPhone 17 Pro simulator XCTest, iOS 26.5: **186 passed**, none skipped.
- macOS target build with normal project signing: **passed**.
- `git diff --check`: **passed**.
- Focused macOS tests use `CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO`;
  the first attempt with normal signing could not load the test bundle because
  host and bundle Team IDs differed. This was a test-host launch failure.

Tests cover native close codes 1000/1001/1008 during a turn, idle recovery,
partial response preservation, unconfirmed draft, HUD failure state, no replay,
intentional teardown, both callback orders, task completion without a receive
callback, and rejection of operations after closure. Fakes require no endpoint.

## Loopback smoke

The fixture binds only to localhost and evicts an existing client when a second
client uses the same client/device identity. It sends only fixed test text and
does not log credentials, prompts, or close reasons. Requires Python's
`websockets` package; the sibling TUI's existing virtual environment can run it.

From the feature worktree, start the fixture in one terminal:

```sh
~/Development/hermes-relay-tui/venv/bin/python scripts/remote-close-smoke.py --code 1008
```

Compile and run the probe in another terminal:

```sh
swiftc -parse-as-library \
  HermesRelayIOS/Models/SessionModels.swift \
  HermesRelayIOS/Models/RelayProfile.swift \
  HermesRelayIOS/Services/HermesSessionClient.swift \
  HermesRelayIOS/Services/HermesEventNormalizer.swift \
  HermesRelayIOS/Services/WebSocketConnection.swift \
  HermesRelayIOS/Services/URLSessionHermesSessionClient.swift \
  scripts/remote-close-smoke.swift -o /tmp/ios34-session-smoke
/tmp/ios34-session-smoke
```

Repeat with `--code 1000` and `--code 1001`. A different fixture port can be
supplied with `--port`; pass the same port as the probe's first argument.

The probe uses the production session client and URLSession transport over real
WebSockets. It checks partial text, duplicate-identity eviction, disconnection,
rejected stale send, and a fresh handshake. This checks transport behavior;
the UI state is covered by the deterministic coordinator tests above.

Result on 2026-09-07: **passed for 1000, 1001, and 1008** on macOS 26.6.2.

## Hardware sign-off — pending

1. Connect the iOS app and a second client to the same test relay with the same
   client/device identity. Use a test account and non-sensitive prompts.
2. Start a turn in the app, then connect the second client.
3. Confirm Thinking ends, partial text remains, and the prompt is unconfirmed.
4. Confirm bounded reconnect and no automatic prompt replay. Disconnect the
   second client to avoid repeated mutual eviction.
5. Repeat with the app idle, then confirm a subsequent typed turn works.

Keep the item in Verify / In Progress until hardware validation and merge.
