"""Loopback-only relay fixture for IOS-34; requires the websockets package.

Connect two clients with the same client_id/device_id to evict the first.
Only fixed test text is sent. No credentials, prompts, or reasons are logged.
"""

import argparse
import asyncio
import json

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


async def main(code: int, port: int) -> None:
    connections = {}

    async def handler(socket):
        identity = None
        try:
            hello = json.loads(await socket.recv())
            if hello.get("type") != "hello":
                await socket.close(code=1008)
                return
            identity = (hello.get("client_id"), hello.get("device_id"))
            previous = connections.get(identity)
            connections[identity] = socket
            if previous is not None:
                await previous.close(code=code)
            await socket.send(json.dumps({"type": "hello_ack", "model": "close-smoke"}))
            async for raw in socket:
                if json.loads(raw).get("type") == "turn":
                    await socket.send(json.dumps({"type": "text_delta", "text": "Partial test response."}))
                    # Leave the turn open until a second client evicts it.
        except ConnectionClosed:
            pass
        finally:
            if connections.get(identity) is socket:
                del connections[identity]

    async with serve(handler, "127.0.0.1", port):
        print(f"IOS-34 fixture ready on loopback port {port}; close code {code}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--code", type=int, choices=[1000, 1001, 1008], default=1008)
    parser.add_argument("--port", type=int, default=18735)
    args = parser.parse_args()
    asyncio.run(main(args.code, args.port))
