#!/usr/bin/env python3
"""Minimal Minecraft RCON client.

Used by the entrypoint to issue a real `stop` on shutdown (SIGTERM does not
make Minecraft save), and exposed as `mc-cmd` for admin commands.

Usage: rcon.py "<command>" [...]
Reads host/port/password from RCON_HOST / RCON_PORT / RCON_PASSWORD.
"""
import os, socket, struct, sys

TYPE_AUTH, TYPE_EXEC = 3, 2

class RconError(Exception):
    pass

def _pack(req_id, req_type, body):
    payload = struct.pack("<ii", req_id, req_type) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload

def _read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RconError("connection closed by server")
        buf += chunk
    return buf

def _read_packet(sock):
    (length,) = struct.unpack("<i", _read_exact(sock, 4))
    if not 10 <= length <= 4_200_000:
        raise RconError(f"implausible packet length {length}")
    payload = _read_exact(sock, length)
    req_id, req_type = struct.unpack("<ii", payload[:8])
    return req_id, req_type, payload[8:-2].decode("utf-8", "replace")

def rcon(command, host, port, password, timeout=30.0):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_pack(1, TYPE_AUTH, password))
        req_id, _, _ = _read_packet(sock)
        # The server answers auth with id -1 when the password is wrong.
        if req_id == -1:
            raise RconError("RCON authentication failed")
        sock.sendall(_pack(2, TYPE_EXEC, command))
        _, _, body = _read_packet(sock)
        return body

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: rcon.py \"<command>\"")
    password = os.environ.get("RCON_PASSWORD", "")
    if not password:
        # `docker exec` does not inherit the runtime-generated password, so fall
        # back to the file the entrypoint wrote.
        try:
            password = open(os.environ.get("RCON_PASSWORD_FILE",
                                           "/data/.rcon_password")).read().strip()
        except OSError:
            pass
    if not password:
        sys.exit("no RCON password (set RCON_PASSWORD or /data/.rcon_password)")
    try:
        out = rcon(" ".join(sys.argv[1:]),
                   os.environ.get("RCON_HOST", "127.0.0.1"),
                   int(os.environ.get("RCON_PORT", "25575")),
                   password)
    except (OSError, RconError) as exc:
        sys.exit(f"rcon: {exc}")
    if out.strip():
        print(out)

if __name__ == "__main__":
    main()
