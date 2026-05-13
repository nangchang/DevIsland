#!/usr/bin/env python3
"""
devisland_pty.py — PTY wrapper for DevIsland hook integration.

Forks a child process under a PTY, forwards all I/O, and reports PTY output
to the DevIsland app via the IPC protocol so auto-inject patterns can fire.

Usage:
    python3 devisland_pty.py [--source SOURCE] [--config PATH] -- COMMAND [ARGS…]

Options:
    --source SOURCE   Provider name sent in IPC envelopes (default: claude).
    --config PATH     Path to bridge-config.json (default: ~/Library/Application
                      Support/DevIsland/bridge-config.json).
"""

import argparse
import json
import os
import pty
import select
import signal
import socket
import struct
import sys
import threading
import time
import uuid
from pathlib import Path


# ---------------------------------------------------------------------------
# Config / IPC helpers
# ---------------------------------------------------------------------------

DEFAULT_CONFIG_PATH = (
    Path.home() / "Library/Application Support/DevIsland/bridge-config.json"
)
DEFAULT_TCP_PORT = 9090
PROTOCOL_NAME = "dev-island-hook-ipc"
PROTOCOL_VERSION = 1


def load_config(config_path: Path) -> dict:
    try:
        with open(config_path) as f:
            return json.load(f)
    except Exception:
        return {}


def read_token() -> str | None:
    token_path = Path.home() / "Library/Application Support/DevIsland/bridge-token"
    try:
        return token_path.read_text().strip()
    except Exception:
        return None


def build_envelope(source: str, session_id: str, payload: dict, token: str | None) -> bytes:
    envelope = {
        "protocol": PROTOCOL_NAME,
        "version": PROTOCOL_VERSION,
        "requestId": str(uuid.uuid4()),
        "sentAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "token": token,
        "source": source,
        "payload": payload,
    }
    body = json.dumps(envelope).encode()
    return struct.pack(">I", len(body)) + body


def send_pty_output(
    source: str,
    session_id: str,
    content: str,
    tcp_port: int,
    token: str | None,
) -> str | None:
    """Send PTYOutput event; return injection string if present, else None."""
    payload = {
        "hook_event_name": "PTYOutput",
        "session_id": session_id,
        "cli_source": source,
        "content": content,
    }
    framed = build_envelope(source, session_id, payload, token)
    try:
        with socket.create_connection(("127.0.0.1", tcp_port), timeout=5) as sock:
            sock.sendall(framed)
            # Read 4-byte length prefix then body
            raw_len = _recv_exactly(sock, 4)
            if not raw_len:
                return None
            (length,) = struct.unpack(">I", raw_len)
            raw_body = _recv_exactly(sock, length)
            if not raw_body:
                return None
            resp = json.loads(raw_body)
            return resp.get("injection")
    except Exception as exc:
        print(f"[devisland_pty] IPC error: {exc}", file=sys.stderr)
        return None


def _recv_exactly(sock: socket.socket, n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


# ---------------------------------------------------------------------------
# PTY fork + I/O loop
# ---------------------------------------------------------------------------

def run_pty(command: list[str], source: str, tcp_port: int) -> int:
    session_id = str(uuid.uuid4())
    token = read_token()

    # Injection queue: items written from IPC thread, consumed by main loop
    injection_queue: list[bytes] = []
    injection_lock = threading.Lock()

    pid, master_fd = pty.fork()

    if pid == 0:
        # Child — exec the command
        os.execvp(command[0], command)
        sys.exit(1)  # unreachable

    # Parent — I/O proxy loop
    def dispatch_pty_output(content: str) -> None:
        """Called in a background thread; queues injection if matched."""
        injection = send_pty_output(source, session_id, content, tcp_port, token)
        if injection:
            with injection_lock:
                injection_queue.append(injection.encode())

    exit_code = 0
    pending_output: list[bytes] = []

    try:
        while True:
            rlist = [master_fd, sys.stdin.fileno()]
            try:
                readable, _, _ = select.select(rlist, [], [], 0.05)
            except (ValueError, OSError):
                break

            for fd in readable:
                if fd == master_fd:
                    try:
                        data = os.read(master_fd, 4096)
                    except OSError:
                        data = b""
                    if not data:
                        readable = []
                        break
                    os.write(sys.stdout.fileno(), data)
                    # Dispatch PTY output to IPC (non-blocking)
                    text = data.decode(errors="replace")
                    threading.Thread(
                        target=dispatch_pty_output, args=(text,), daemon=True
                    ).start()

                elif fd == sys.stdin.fileno():
                    try:
                        data = os.read(sys.stdin.fileno(), 256)
                    except OSError:
                        data = b""
                    if data:
                        os.write(master_fd, data)

            # Drain injection queue → write to PTY stdin
            with injection_lock:
                queued = injection_queue[:]
                injection_queue.clear()
            for inj in queued:
                try:
                    os.write(master_fd, inj)
                except OSError:
                    pass

            # Check child exit
            try:
                wpid, wstatus = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    exit_code = os.waitstatus_to_exitcode(wstatus)
                    break
            except ChildProcessError:
                break

    except KeyboardInterrupt:
        try:
            os.kill(pid, signal.SIGINT)
        except ProcessLookupError:
            pass

    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass

    return exit_code


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="DevIsland PTY wrapper",
        usage="%(prog)s [--source SOURCE] [--config PATH] -- COMMAND [ARGS…]",
    )
    parser.add_argument("--source", default="claude", help="Provider name (default: claude)")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    parser.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("No command specified after --")

    config = load_config(args.config)
    tcp_port = int(config.get("bridgeTcpPort", DEFAULT_TCP_PORT))

    sys.exit(run_pty(command, args.source, tcp_port))


if __name__ == "__main__":
    main()
