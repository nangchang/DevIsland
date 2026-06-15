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


_LOG_DIR = Path.home() / "Library" / "Logs" / "DevIsland"
LOG_PATH = str(_LOG_DIR / "bridge.log")
_LOG_MAX_BYTES = 5 * 1024 * 1024  # 5 MB

# Events forwarded to the app (all others are suppressed before reaching the app).
# Derived from the canonical hook_events.json manifest so this list stays in sync.
# If the manifest is missing or malformed at runtime (e.g. an incomplete install),
# fall back to this snapshot so a hook invocation never crashes the user's CLI
# session at import time. A regression test keeps it equal to the manifest set.
_FALLBACK_PASSIVE_EVENTS: frozenset[str] = frozenset({
    "PermissionRequest",
    "SessionStart",
    "SessionEnd",
    "Notification",
    "Stop",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "UserPromptSubmit",
    "Elicitation",
    "BeforeTool",
    "AfterAgent",
    "PreInvocation",
    "PostInvocation",
})


def _load_passive_events() -> frozenset[str]:
    manifest_path = Path(__file__).parent / "hook_events.json"
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        events: set[str] = set()
        for key, value in manifest.items():
            if key.startswith("_"):
                # Special keys like _bridge_extras are treated as a flat list.
                events.update(value)
            else:
                events.update(value.get("active", []))
                events.update(value.get("lifecycle", []))
        return frozenset(events)
    except (OSError, json.JSONDecodeError):
        return _FALLBACK_PASSIVE_EVENTS


PASSIVE_EVENTS: frozenset[str] = _load_passive_events()


def _normalize_event(name: str) -> str:
    """Mirror HookEventNormalizer.normalizedName in Swift: lowercase, strip _ and -."""
    return name.lower().replace("_", "").replace("-", "")


# Pre-normalized allow-list so the membership test is case- and separator-insensitive.
_PASSIVE_EVENTS_NORMALIZED = frozenset(_normalize_event(e) for e in PASSIVE_EVENTS)

_APP_SUPPORT = Path("~/Library/Application Support/DevIsland").expanduser()
_TOKEN_PATH = _APP_SUPPORT / "bridge-token"
_CONFIG_PATH = _APP_SUPPORT / "bridge-config.json"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(message: str) -> None:
    # Best-effort: logging must never raise and must never affect hook output.
    try:
        _LOG_DIR.mkdir(parents=True, exist_ok=True)
        log_path = Path(LOG_PATH)
        if log_path.exists() and log_path.stat().st_size > _LOG_MAX_BYTES:
            rotated = log_path.with_suffix(".1.log")
            log_path.replace(rotated)
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        fd = os.open(LOG_PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            with os.fdopen(fd, "a", encoding="utf-8") as handle:
                handle.write(f"[{timestamp}] {message}\n")
        except Exception:
            pass
    except Exception:
        pass


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


def enrich_payload(payload: dict[str, Any], cli_source_arg: str, event_arg: str = "") -> dict[str, Any]:
    def set_if_present(key: str, env_name: str, default: str = ""):
        val = os.environ.get(env_name, "")
        if val:
            payload[key] = val
        elif key not in payload:
            payload[key] = default

    set_if_present("terminal_title", "TERM_TITLE", "Terminal")
    set_if_present("terminal_app", "TERM_APP", "")
    set_if_present("terminal_tty", "TERM_TTY", "")
    set_if_present("terminal_window_id", "TERM_WINDOW_ID", "")
    set_if_present("terminal_tab_index", "TERM_TAB_INDEX", "")
    set_if_present("terminal_tmux_pane", "TERM_TMUX_PANE", "")
    set_if_present("terminal_tmux_socket", "TERM_TMUX_SOCKET", "")
    set_if_present("terminal_tmux_client", "TERM_TMUX_CLIENT", "")
    payload["cli_source"] = cli_source_arg
    if cli_source_arg == "antigravity":
        normalize_antigravity_payload(payload, event_arg)
    return payload


def normalize_antigravity_payload(payload: dict[str, Any], event_arg: str = "") -> None:
    if "hook_event_name" not in payload and event_arg:
        payload["hook_event_name"] = event_arg
    elif "hook_event_name" not in payload:
        payload["hook_event_name"] = event_name(payload)

    if "session_id" not in payload:
        conversation_id = payload.get("conversationId")
        if conversation_id:
            payload["session_id"] = str(conversation_id)

    tool_call = payload.get("toolCall")
    if isinstance(tool_call, dict):
        if "tool_name" not in payload and tool_call.get("name"):
            payload["tool_name"] = str(tool_call["name"])
        if "tool_input" not in payload:
            args = tool_call.get("args")
            payload["tool_input"] = args if isinstance(args, dict) else {}

    if "cwd" not in payload:
        tool_input = payload.get("tool_input")
        if isinstance(tool_input, dict):
            cwd = tool_input.get("Cwd") or tool_input.get("cwd")
            if cwd:
                payload["cwd"] = str(cwd)
        if "cwd" not in payload:
            workspace_paths = payload.get("workspacePaths")
            if isinstance(workspace_paths, list) and workspace_paths:
                payload["cwd"] = str(workspace_paths[0])


def event_name(payload: dict[str, Any]) -> str:
    if "hook_event_name" in payload:
        return str(payload["hook_event_name"])
    if "event" in payload:
        return str(payload["event"])

    cli_source = payload.get("cli_source", "")
    if cli_source == "antigravity":
        if "toolCall" in payload:
            return "PreToolUse"
        elif "tool_response" in payload or "error" in payload:
            return "PostToolUse"
        elif "initialNumSteps" in payload:
            return "PreInvocation"

    return "PermissionRequest"


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


def load_config() -> dict[str, Any]:
    try:
        return json.loads(_CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def send_to_app(payload: dict[str, Any], source: str) -> tuple[str, dict[str, Any] | None]:
    """Send an IPC v1 envelope to the app and return (decision, providerOutput|None).

    If a framed request receives an unframed response, treat that as a version
    mismatch and fail closed.
    """
    config = load_config()
    token = load_token()
    envelope = build_envelope(payload, source, token)
    body = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    transport = str(config.get("bridgeTransportKind", "tcpLoopback"))
    socket_path = str(config.get("bridgeSocketPath") or str(_APP_SUPPORT / "dev-island.sock"))
    fallback_to_tcp = bool(config.get("bridgeFallbackToTcp", True))
    port = int(config.get("bridgeTcpPort", 9090))
    connect_timeout = float(config.get("bridgeConnectTimeoutSeconds", 5))
    response_timeout = float(config.get("bridgeResponseTimeoutSeconds", 300))

    if transport == "unixDomainSocket":
        try:
            raw = _send_unix_frame(socket_path, frame, connect_timeout, response_timeout)
        except OSError as error:
            if not fallback_to_tcp:
                raise
            log(f"UDS transport failed ({error}); falling back to TCP")
            raw = _send_tcp_frame(port, frame, connect_timeout, response_timeout)
    else:
        raw = _send_tcp_frame(port, frame, connect_timeout, response_timeout)
    return _parse_response(raw, framed_request=True)


def _send_tcp_frame(port: int, frame: bytes, connect_timeout: float, response_timeout: float) -> bytes:
    with socket.create_connection(("127.0.0.1", port), timeout=connect_timeout) as sock:
        return _send_frame(sock, frame, response_timeout)


def _send_unix_frame(path: str, frame: bytes, connect_timeout: float, response_timeout: float) -> bytes:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(connect_timeout)
        sock.connect(path)
        return _send_frame(sock, frame, response_timeout)


def _send_frame(sock: socket.socket, frame: bytes, response_timeout: float) -> bytes:
    sock.settimeout(response_timeout)
    sock.sendall(frame)
    # Half-close write so EOF-based transports can detect end-of-message.
    # Length-prefixed servers read exactly `length` bytes and ignore the FIN, so this is safe.
    sock.shutdown(socket.SHUT_WR)

    response_chunks: list[bytes] = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        response_chunks.append(chunk)
    return b"".join(response_chunks)


def _parse_response(raw: bytes, *, framed_request: bool = False) -> tuple[str, dict[str, Any] | None]:
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

    if framed_request:
        # A v1-capable app must answer a framed request with a framed response. If a
        # legacy app receives the binary-prefixed envelope as raw JSON, it may parse
        # failure as a harmless notification and return {"response":"approved"}.
        # Treat that version mismatch as fail-closed instead of trusting the raw body.
        return "denied", None

    # Legacy raw JSON response: {"response": "approved|denied|pass"}
    try:
        obj = json.loads(raw)
        return str(obj.get("response", "pass")), None
    except Exception:
        # Intentional: malformed response is treated as pass so the CLI can
        # continue unblocked. DevIsland is an optional overlay — if it cannot
        # produce a valid response, the default is to stay out of the way.
        return "pass", None


# ---------------------------------------------------------------------------
# Transport failure fallback
# ---------------------------------------------------------------------------

def fallback_decision() -> str:
    """Return the fallback decision when the app is unreachable.

    Reads approvalFallbackPolicy from bridge-config.json; defaults to "pass".
    "deny" → deny, everything else → "pass" (let the CLI handle it).

    Intentional design: the default fallback is pass, not deny.
    DevIsland is an optional approval overlay. When the app is not running
    (e.g. user hasn't launched it, it crashed, or it's not installed), the
    bridge steps aside and lets the CLI's own permission system take over.
    Fail-closed ("deny") is available as an opt-in policy for users
    who want hard enforcement even when the app is absent.
    """
    policy = load_config().get("approvalFallbackPolicy", "pass")
    return "deny" if policy == "deny" else "pass"


# ---------------------------------------------------------------------------
# Provider-specific output
# ---------------------------------------------------------------------------

def final_output(*, event: str, decision: str, provider_output: dict[str, Any] | None, cli_source: str) -> dict[str, Any]:
    # If the app already provided formatted provider output, use it directly.
    if provider_output:
        return provider_output

    message = "DevIsland에서 거절되었습니다."

    if decision == "pass":
        if cli_source == "claude" and event != "permissionrequest":
            return {"continue": True, "suppressOutput": True}
        if cli_source == "antigravity" and event == "pretooluse":
            return {"decision": "ask"}
        return {}

    allow = decision == "approved"
    if cli_source == "gemini":
        if event == "beforetool":
            output: dict[str, Any] = {"decision": "allow" if allow else "deny"}
            if not allow:
                output["reason"] = message
            return output
        return {}

    if cli_source == "antigravity":
        if event == "pretooluse":
            output: dict[str, Any] = {"decision": "allow" if allow else "deny"}
            if not allow:
                output["reason"] = message
            return output
        return {}

    if cli_source == "codex":
        if event == "pretooluse":
            if allow:
                return {}
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            }
        if event != "permissionrequest":
            return {"continue": True}

    if cli_source == "claude":
        if event == "userpromptsubmit":
            if allow:
                return {"continue": True, "suppressOutput": True}
            return {"decision": "block", "reason": message}
        if event == "elicitation":
            if allow:
                return {"continue": True, "suppressOutput": True}
            return {
                "hookSpecificOutput": {
                    "hookEventName": "Elicitation",
                    "action": "decline",
                }
            }

    if event == "permissionrequest" and decision in ("approved", "denied"):
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
    parser.add_argument("--event", default="")
    args = parser.parse_args()

    cli_source = args.source
    payload = enrich_payload(load_payload(), cli_source, args.event)
    event = event_name(payload)
    norm_event = _normalize_event(event)

    session_id = payload.get("session_id", "")[:8]
    log(f"Event: {event} session={session_id} source={cli_source}")
    event = norm_event

    if event not in _PASSIVE_EVENTS_NORMALIZED:
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
