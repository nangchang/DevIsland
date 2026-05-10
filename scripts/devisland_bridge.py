#!/usr/bin/env python3
"""DevIsland hook bridge payload processing and IPC transport (protocol v1)."""

from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LOG_PATH = "/tmp/DevIsland.bridge.log"

# Events forwarded to the app (all others are suppressed before reaching the app).
PASSIVE_EVENTS = {
    "PermissionRequest",
    "SessionStart",
    "SessionEnd",
    "Notification",
    "Stop",
    "PreToolUse",
    "PostToolUse",
    "BeforeTool",
    "AfterAgent",
}

_APP_SUPPORT = Path("~/Library/Application Support/DevIsland").expanduser()
_TOKEN_PATH = _APP_SUPPORT / "bridge-token"
_CONFIG_PATH = _APP_SUPPORT / "bridge-config.json"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(message: str) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] {message}\n")


# ---------------------------------------------------------------------------
# Payload helpers
# ---------------------------------------------------------------------------

def load_payload() -> dict[str, Any]:
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def dump(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def enrich_payload(payload: dict[str, Any], cli_source_arg: str) -> dict[str, Any]:
    payload["terminal_title"] = os.environ.get("TERM_TITLE", "Terminal")
    payload["terminal_app"] = os.environ.get("TERM_APP", "")
    payload["terminal_tty"] = os.environ.get("TERM_TTY", "")
    payload["terminal_window_id"] = os.environ.get("TERM_WINDOW_ID", "")
    payload["terminal_tab_index"] = os.environ.get("TERM_TAB_INDEX", "")
    payload["terminal_tmux_pane"] = os.environ.get("TERM_TMUX_PANE", "")
    payload["terminal_tmux_socket"] = os.environ.get("TERM_TMUX_SOCKET", "")
    payload["terminal_tmux_client"] = os.environ.get("TERM_TMUX_CLIENT", "")
    payload["cli_source"] = cli_source_arg
    return payload


def event_name(payload: dict[str, Any]) -> str:
    return str(payload.get("hook_event_name", payload.get("event", "PermissionRequest")))


# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------

def load_token() -> str | None:
    try:
        return _TOKEN_PATH.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


# ---------------------------------------------------------------------------
# IPC protocol v1: envelope + length-prefixed framing
# ---------------------------------------------------------------------------

def build_envelope(payload: dict[str, Any], source: str, token: str | None) -> dict[str, Any]:
    envelope: dict[str, Any] = {
        "protocol": "dev-island-hook-ipc",
        "version": 1,
        "requestId": str(uuid.uuid4()),
        "sentAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": source,
        "payload": payload,
    }
    if token is not None:
        envelope["token"] = token
    return envelope


def send_to_app(payload: dict[str, Any], source: str) -> tuple[str, dict[str, Any] | None]:
    """Send an IPC v1 envelope to the app and return (decision, providerOutput|None).

    Falls back to a legacy raw-JSON exchange if the app responds without framing.
    """
    token = load_token()
    envelope = build_envelope(payload, source, token)
    body = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    with socket.create_connection(("127.0.0.1", 9090), timeout=5) as sock:
        sock.settimeout(300)
        sock.sendall(frame)
        # Do NOT shutdown write — framing signals message boundary.

        response_chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            response_chunks.append(chunk)

    raw = b"".join(response_chunks)
    return _parse_response(raw)


def _parse_response(raw: bytes) -> tuple[str, dict[str, Any] | None]:
    """Return (decision, providerOutput|None).

    Handles both framed rich responses and legacy raw-JSON responses.
    """
    if not raw:
        return "pass", None

    if raw[0] == 0 and len(raw) >= 4:
        # Length-prefixed rich response.
        length = struct.unpack(">I", raw[:4])[0]
        try:
            obj = json.loads(raw[4: 4 + length])
        except Exception:
            return "pass", None
        provider_output = obj.get("providerOutput") or None
        decision = obj.get("decision") or "pass"
        return decision, provider_output

    # Legacy raw JSON response: {"response": "approved|denied|pass"}
    try:
        obj = json.loads(raw)
        return str(obj.get("response", "pass")), None
    except Exception:
        return "pass", None


# ---------------------------------------------------------------------------
# Transport failure fallback
# ---------------------------------------------------------------------------

def fallback_decision() -> str:
    """Return the fallback decision when the app is unreachable.

    Reads approvalFallbackPolicy from bridge-config.json; defaults to "deny".
    "allowReadOnly" maps to "pass" (let the CLI handle it), everything else → "deny".
    """
    try:
        config = json.loads(_CONFIG_PATH.read_text(encoding="utf-8"))
        policy = config.get("approvalFallbackPolicy", "denyUnknown")
    except OSError:
        policy = "denyUnknown"
    return "pass" if policy == "allowReadOnly" else "deny"


# ---------------------------------------------------------------------------
# Provider-specific output
# ---------------------------------------------------------------------------

def final_output(*, event: str, decision: str, provider_output: dict[str, Any] | None, cli_source: str) -> dict[str, Any]:
    # If the app already provided formatted provider output, use it directly.
    if provider_output:
        return provider_output

    message = "DevIsland에서 거절되었습니다."

    if decision == "pass":
        if cli_source == "claude":
            return {"continue": True, "suppressOutput": True}
        return {}

    allow = decision == "approved"
    if cli_source == "gemini":
        output: dict[str, Any] = {"decision": "allow" if allow else "deny"}
        if not allow:
            output["reason"] = message
        return output

    if cli_source == "codex":
        if event == "PreToolUse":
            if allow:
                return {}
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            }
        if event != "PermissionRequest":
            return {"continue": True}

    if event == "PermissionRequest" and decision in ("approved", "denied"):
        hook_decision: dict[str, Any] = {"behavior": "allow" if allow else "deny"}
        if not allow:
            hook_decision["message"] = message
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": hook_decision,
            }
        }

    return {"continue": True, "suppressOutput": True}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    args = parser.parse_args()

    cli_source = args.source
    payload = enrich_payload(load_payload(), cli_source)
    event = event_name(payload)

    log(f"Raw Payload: {dump(payload)}")
    log(f"Event Detected: {event} (Source: {cli_source})")

    if event not in PASSIVE_EVENTS:
        log(f"Passive event suppressed before app: {event}")
        print('{"continue":true,"suppressOutput":true}')
        return 0

    try:
        decision, provider_output = send_to_app(payload, cli_source)
        log(f"Decision: {decision}, hasProviderOutput: {provider_output is not None}")
    except Exception as error:
        log(f"Bridge transport error: {error}")
        decision = fallback_decision()
        provider_output = None
        log(f"Fallback decision: {decision}")

    output = final_output(event=event, decision=decision, provider_output=provider_output, cli_source=cli_source)
    final = dump(output)
    log(f"Final Output: {final}")
    print(final)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
