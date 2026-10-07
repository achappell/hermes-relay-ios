"""IOS-HOME-08 production Apple store/bridge loopback smoke (macOS, Xcode).

Run from the repository root:
  export PATH=/opt/homebrew/bin:$PATH
  export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
  python3 scripts/home-tail-interrupt-smoke.py
Requires Python 3.11+ and websockets (same dependency as remote-close-smoke.py).
Compiles the checked-out Models, Services, and ViewModels with xcrun swiftc,
then runs the companion Swift executable against a temporary TLS peer. Use
--binary /path/to/executable to reuse an explicitly compiled companion.

This is a Home-contract fixture, NOT deployed Home or native playback evidence.
Only synthetic text and silence cross loopback. No Keychain, user profile,
system trust, household endpoint, or device is used. Temporary TLS material,
configuration, isolated diagnostics, and executable are removed on exit.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import platform
import ssl
import subprocess
import tempfile

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


HANDLE = "smoke-conversation"
PROMPTS = ["synthetic tail", "synthetic active", "synthetic next"]


async def run(binary, directory, context):
    submissions = []
    interrupts = []
    terminals = []
    signals = {}
    failures = []
    connections = 0
    handlers = set()
    phases = {"http_upgrade": 0, "websocket_open": 0, "open_reply": 0}

    async def process_request(connection, request):
        phases["http_upgrade"] += 1
        return None

    async def marker(name):
        await signals.setdefault(name, asyncio.Event()).wait()

    async def handler(socket):
        nonlocal connections
        connections += 1
        phases["websocket_open"] += 1
        handlers.add(asyncio.current_task())
        final_terminal_sent = False
        try:
            assert connections == 1, "Unexpected reconnect/replay socket"
            assert socket.request.path == "/api/v1/bridge/ws"
            assert socket.request.headers.get("Authorization") == "Device loopback-only"

            async def send(method, params):
                await socket.send(json.dumps({"jsonrpc": "2.0", "schema": 1,
                                              "method": method, "params": params}))

            async def event(turn, kind, payload=None):
                if kind in ("turn_complete", "turn_interrupted"):
                    terminals.append((turn, kind))
                await send("event", {"schema": 1, "conversation_handle": HANDLE,
                                    "turn_id": turn,
                                    "event": {"type": kind, "payload": payload or {}}})

            async def audio(kind):
                frame = {"kind": kind}
                if kind == "start":
                    frame.update(sample_rate=24000, channels=1,
                                 sample_width=2, byte_order="little")
                await send("audio.frame", {"schema": 1, "conversation_handle": HANDLE,
                                           "turn_id": "turn-1", "frame": frame})

            async for raw in socket:
                request = json.loads(raw)
                method, params = request["method"], request["params"]
                assert request["jsonrpc"] == "2.0"
                result = None
                turn = None
                if method == "conversation.open":
                    result = {"schema": 1, "status": "ready", "conversation_handle": HANDLE,
                              "route": {"class": "home", "id": "smoke"},
                              "capabilities": {"commands": [], "timing": "absent",
                                               "interrupt": True, "audio": True},
                              "unresolved_turn": False}
                elif method == "prompt.submit":
                    submissions.append(params["text"])
                    assert submissions == PROMPTS[:len(submissions)], "Duplicate or unexpected prompt"
                    assert len(submissions) <= 3
                    turn = f"turn-{len(submissions)}"
                    result = {"schema": 1, "status": "submitted",
                              "conversation_handle": HANDLE, "turn_id": turn}
                elif method == "session.interrupt":
                    turn = params["turn_id"]
                    interrupts.append(turn)
                    assert interrupts == ["turn-1", "turn-2"][:len(interrupts)]
                    result = {"status": "accepted"}
                    if turn == "turn-1":
                        # Home releases sidecar admission before replying to stop.
                        await audio("end")
                else:
                    raise AssertionError(f"Unexpected wire method: {method}")
                await socket.send(json.dumps({"jsonrpc": "2.0", "schema": 1,
                                              "id": request["id"], "result": result}))
                if method == "conversation.open":
                    phases["open_reply"] += 1
                if method == "prompt.submit":
                    await marker(f"accepted-{turn}")
                    await event(turn, "message.delta", {"rendered": "Synthetic response", "kind": "assistant"})
                    if turn == "turn-1":
                        await audio("start")
                        await socket.send(b"\x00\x00")
                        await event(turn, "turn_complete")
                    elif turn == "turn-3":
                        await event(turn, "turn_complete")
                        final_terminal_sent = True
                elif method == "session.interrupt":
                    if turn == "turn-2":
                        await event("turn-1", "turn_interrupted")  # stale scope must not settle turn 2
                        await event(turn, "status", {"text": "smoke-ack-gate"})
                        await marker("release-active-terminal")
                        await event(turn, "turn_interrupted")
        except ConnectionClosed as error:
            # URLSession cancellation can end the TCP connection without a
            # close frame. Accept it only after this complete scenario; the
            # executable's exit status still proves all client assertions ran.
            if not (final_terminal_sent and submissions == PROMPTS
                    and interrupts == ["turn-1", "turn-2"]):
                failures.append("Premature connection close: " + type(error).__name__)
        except Exception as error:
            failures.append(type(error).__name__ + ": " + str(error))
            await socket.close(code=1011)

    async with serve(handler, "127.0.0.1", 0, ssl=context, process_request=process_request) as server:
        port = server.sockets[0].getsockname()[1]
        environment = dict(os.environ, HOME=str(directory), CFFIXED_USER_HOME=str(directory))
        process = await asyncio.create_subprocess_exec(
            str(binary), str(port), str(directory), env=environment, stdout=asyncio.subprocess.PIPE
        )

        async def receive_signals():
            async for raw in process.stdout:
                line = raw.decode().rstrip()
                if line.startswith("SMOKE "):
                    signals.setdefault(line[6:], asyncio.Event()).set()
                else:
                    print(line, flush=True)

        reader = asyncio.create_task(receive_signals())
        try:
            async with asyncio.timeout(30):
                code = await process.wait()
        except BaseException:
            if process.returncode is None:
                process.kill()
                await process.wait()
            raise
        finally:
            for task in handlers:
                task.cancel()
            await asyncio.gather(*handlers, return_exceptions=True)
            await reader
            print("Smoke peer phases: " + json.dumps(phases, sort_keys=True), flush=True)
    assert not failures, "; ".join(failures)
    assert code == 0, f"Swift smoke exited {code}; peer phases={phases}"
    assert submissions == PROMPTS, "Not all explicit prompts reached Home peer exactly once"
    assert interrupts == ["turn-1", "turn-2"]
    assert terminals.count(("turn-1", "turn_complete")) == 1
    assert terminals == [("turn-1", "turn_complete"), ("turn-1", "turn_interrupted"),
                         ("turn-2", "turn_interrupted"), ("turn-3", "turn_complete")]
    print("PASS: loopback Home-contract peer saw three explicit submissions, two interrupts, no replay")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="hermes-home-tail-smoke-") as temporary:
        directory = Path(temporary)
        binary = args.binary.resolve() if args.binary else directory / "home-tail-smoke"
        if not args.binary:
            sources = sorted(path for folder in ("Models", "Services", "ViewModels")
                             for path in (root / "HermesRelay" / folder).glob("*.swift"))
            command = ["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library",
                       "-swift-version", "6", "-target", f"{platform.machine()}-apple-macos26.0",
                       "-module-name", "HermesRelayIOS", *map(str, sources),
                       str(root / "scripts/home-tail-interrupt-smoke.swift"), "-o", str(binary)]
            print("Compiling checked-out production sources (no app entrypoint or XCTest doubles)", flush=True)
            subprocess.run(command, check=True, cwd=root)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"),
                        "-days", "1", "-subj", "/CN=127.0.0.1",
                        "-addext", "subjectAltName=IP:127.0.0.1",
                        "-addext", "extendedKeyUsage=serverAuth",
                        "-addext", "keyUsage=critical,digitalSignature,keyEncipherment"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "x509", "-in", str(directory / "cert.pem"), "-outform", "DER",
                        "-out", str(directory / "cert.der")], check=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(directory / "cert.pem", directory / "key.pem")
        asyncio.run(run(binary, directory, context))


if __name__ == "__main__":
    main()
