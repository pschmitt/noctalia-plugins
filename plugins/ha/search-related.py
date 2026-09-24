#!/usr/bin/env python3
"""Print the automations, scripts, scenes and groups that reference an entity.

Home Assistant only exposes its "related" search over the websocket API
(`search/related`), which Noctalia's Luau runtime cannot speak, so the service
runs this helper instead. It deliberately sticks to the standard library: the
websocket client below implements just enough of RFC 6455 (client handshake,
masked text frames, fragmentation, ping/pong) for this one request.

The server URL and token are read from the same files the plugin is configured
with, so the token never appears on a command line.

Usage: search-related.py SERVER_FILE TOKEN_FILE ENTITY_ID [--insecure]
Output: one `<type>\t<entity_id>` line per related entity.
"""

import base64
import json
import os
import socket
import ssl
import struct
import sys
import urllib.parse

TYPES = ("automation", "script", "scene", "group")
TIMEOUT = 10


def read_file(path):
    with open(os.path.expanduser(path.strip()), encoding="utf-8") as handle:
        return handle.read().strip()


def connect(server, insecure):
    url = urllib.parse.urlsplit(server.rstrip("/"))
    secure = url.scheme == "https"
    port = url.port or (443 if secure else 80)
    sock = socket.create_connection((url.hostname, port), timeout=TIMEOUT)
    if secure:
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        sock = context.wrap_socket(sock, server_hostname=url.hostname)

    key = base64.b64encode(os.urandom(16)).decode()
    host = url.hostname if url.port is None else f"{url.hostname}:{url.port}"
    path = url.path.rstrip("/") + "/api/websocket"
    sock.sendall(
        (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("connection closed during websocket handshake")
        response += chunk
    head, rest = response.split(b"\r\n\r\n", 1)
    status = head.split(b"\r\n", 1)[0]
    if b" 101 " not in status + b" ":
        raise ConnectionError(f"websocket handshake failed: {status.decode(errors='replace')}")
    return sock, bytearray(rest)


class Connection:
    def __init__(self, sock, buffered):
        self.sock = sock
        self.buffer = buffered

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by Home Assistant")
            self.buffer += chunk
        data = bytes(self.buffer[:count])
        del self.buffer[:count]
        return data

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack("!H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def send(self, message):
        self._send_frame(0x1, json.dumps(message).encode())

    def recv(self):
        message = b""
        while True:
            first, second = self._read(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._read(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._read(8))
            mask = self._read(4) if second & 0x80 else None
            payload = self._read(length)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("connection closed by Home Assistant")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if first & 0x80:
                return json.loads(message)


def main(argv):
    if len(argv) < 4:
        print("usage: search-related.py SERVER_FILE TOKEN_FILE ENTITY_ID [--insecure]", file=sys.stderr)
        return 2
    server = read_file(argv[1])
    token = read_file(argv[2])
    entity_id = argv[3]
    insecure = "--insecure" in argv[4:]

    ws = Connection(*connect(server, insecure))
    if ws.recv().get("type") != "auth_required":
        raise ConnectionError("unexpected websocket greeting")
    ws.send({"type": "auth", "access_token": token})
    auth = ws.recv()
    if auth.get("type") != "auth_ok":
        raise PermissionError(auth.get("message") or "authentication failed")

    ws.send({"id": 1, "type": "search/related", "item_type": "entity", "item_id": entity_id})
    while True:
        reply = ws.recv()
        if reply.get("id") == 1:
            break
    if not reply.get("success"):
        raise RuntimeError((reply.get("error") or {}).get("message") or "search failed")

    result = reply.get("result") or {}
    for kind in TYPES:
        for related_id in sorted(result.get(kind) or []):
            if related_id != entity_id:
                print(f"{kind}\t{related_id}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as error:  # noqa: BLE001 -- surfaced to the panel verbatim
        print(error, file=sys.stderr)
        sys.exit(1)
