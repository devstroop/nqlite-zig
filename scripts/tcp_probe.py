#!/usr/bin/env python3
"""TCP parity probe: `nql-server` (default transport) vs `nqlite_zig --tcp`.

Boots each server on a free port with its own fresh `.ndb` store, replays
one fixed line-protocol program over a real socket, then reconnects for a
persistence check — and byte-compares the two transcripts.

Run:  python3 scripts/tcp_probe.py        (from nqlite-zig root)
Exit: 0 = byte-identical, 1 = divergence (diff printed).
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUST = Path("/root/ai-workspace/nqlite/target/debug/nql-server")
ZIG = ROOT / "zig-out/bin/nqlite_zig"

# One program per line. Session 1 writes + queries; session 2 (fresh
# connection) proves the shared database survived the reconnect.
SESSION_1 = [
    "CREATE TABLE note VECTOR<f32,4>",
    'INSERT INTO note:1 { text: "tcp probe one", topic: "a" } EMBED [0.1, 0.2, 0.3, 0.4]',
    'INSERT INTO note:2 { text: "tcp probe two", topic: "b" }',
    "RELATE (note:1) -> :ref -> (note:2) SET weight = 0.5",
    "SELECT * FROM note",
    "MATCH (note:1) -> :ref;",
    "SELECT * FROM note AS OF 2",
    "HISTORY SINCE 0",
    "SELECT COUNT(*) FROM note",
    "SELECT * FROM missing",
]
SESSION_2 = [
    "SELECT * FROM note",
    "SELECT COUNT(*) FROM note",
]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_listening(port: int, proc: subprocess.Popen, timeout: float = 15.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited early (rc={proc.returncode})")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return  # kernel-level liveness; probe conn closes immediately
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("server never listened")


def run_script(port: int, lines: list[str]) -> bytes:
    """Send every line, then read until the server goes quiet."""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        sock.settimeout(2.0)
        for line in lines:
            sock.sendall(line.encode() + b"\n")
        buf = b""
        idle = 0
        while idle < 4:  # ~0.5s of silence = done (per-line flush server)
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
                idle = 0
            except socket.timeout:
                idle += 1
        return buf


def transcript(binary: Path, args: list[str], db: Path, port: int) -> bytes:
    for suffix in ("", ".wal", ".lock"):
        p = Path(str(db) + suffix)
        if p.exists():
            p.unlink()
    env = dict(os.environ, PORT=str(port))
    proc = subprocess.Popen(
        [str(binary), *args, "--db", str(db)],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        wait_listening(port, proc)
        out = run_script(port, SESSION_1)
        out += b"--- session 2 (reconnect) ---\n"
        out += run_script(port, SESSION_2)
        return out
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def main() -> int:
    for b in (RUST, ZIG):
        if not b.exists():
            print(f"missing binary: {b}", file=sys.stderr)
            return 2
    tmp = Path(tempfile.mkdtemp(prefix="tcp-probe-"))
    try:
        p_rust, p_zig = free_port(), free_port()
        rust = transcript(RUST, [], tmp / "rust.ndb", p_rust)
        zig = transcript(ZIG, ["--tcp"], tmp / "zig.ndb", p_zig)
        if rust == zig:
            n = rust.count(b"OK") + rust.count(b"ERR")
            print(f"TCP parity: IDENTICAL ({len(rust)} bytes, "
                  f"{n} responses, 2 sessions each)")
            return 0
        print("TCP parity: DIVERGED")
        import difflib
        for line in difflib.unified_diff(
            rust.decode(errors="replace").splitlines(),
            zig.decode(errors="replace").splitlines(),
            fromfile="nql-server", tofile="nqlite_zig --tcp", lineterm="",
        ):
            print(line)
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
