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
from typing import Any, ClassVar


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
    "SubagentStart",
    "SubagentStop",
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

_DENIAL_MESSAGE = "DevIsland에서 거절되었습니다."
_APPROVAL_OWNER_ENV = "DEVISLAND_CODEX_APPROVAL_OWNER"
_APPROVAL_OWNER_FIELD = "devisland_approval_owner"


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
# Provider adapters
# ---------------------------------------------------------------------------
# Each adapter owns the per-CLI logic for three concerns:
#   normalize_payload  — mutates the raw payload into DevIsland's canonical form
#   final_output       — formats the hook response JSON the CLI expects
#
# New CLIs: add a subclass with a `sources` tuple. No other file changes needed.
# ---------------------------------------------------------------------------

def _permission_request_output(allow: bool) -> dict[str, Any]:
    hook_decision: dict[str, Any] = {"behavior": "allow" if allow else "deny"}
    if not allow:
        hook_decision["message"] = _DENIAL_MESSAGE
    return {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": hook_decision,
        }
    }


class ProviderAdapter:
    sources: tuple[str, ...] = ()
    _registry: ClassVar[dict[str, ProviderAdapter]] = {}

    def __init_subclass__(cls, **kwargs: Any) -> None:
        super().__init_subclass__(**kwargs)
        instance = cls()
        for source in cls.sources:
            ProviderAdapter._registry[source] = instance

    def normalize_payload(self, payload: dict[str, Any], event_arg: str) -> None:
        pass

    def final_output(self, event: str, decision: str) -> dict[str, Any]:
        if decision == "pass":
            return {}
        if event == "permissionrequest" and decision in ("approved", "denied"):
            return _permission_request_output(decision == "approved")
        return {"continue": True, "suppressOutput": True}


class _ClaudeAdapter(ProviderAdapter):
    sources = ("claude",)

    def final_output(self, event: str, decision: str) -> dict[str, Any]:
        if decision == "pass":
            return {"continue": True, "suppressOutput": True} if event != "permissionrequest" else {}
        allow = decision == "approved"
        if event == "userpromptsubmit":
            return (
                {"continue": True, "suppressOutput": True}
                if allow
                else {"decision": "block", "reason": _DENIAL_MESSAGE}
            )
        if event == "elicitation":
            return (
                {"continue": True, "suppressOutput": True}
                if allow
                else {"hookSpecificOutput": {"hookEventName": "Elicitation", "action": "decline"}}
            )
        if event == "permissionrequest" and decision in ("approved", "denied"):
            return _permission_request_output(allow)
        return {"continue": True, "suppressOutput": True}


class _CodexAdapter(ProviderAdapter):
    sources = ("codex",)

    def final_output(self, event: str, decision: str) -> dict[str, Any]:
        if decision == "pass":
            return {}
        allow = decision == "approved"
        if event == "pretooluse":
            if allow:
                return {}
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": _DENIAL_MESSAGE,
                }
            }
        if event != "permissionrequest":
            return {"continue": True}
        if decision in ("approved", "denied"):
            return _permission_request_output(allow)
        return {}


class _GeminiAdapter(ProviderAdapter):
    sources = ("gemini",)

    def final_output(self, event: str, decision: str) -> dict[str, Any]:
        if decision == "pass":
            return {}
        allow = decision == "approved"
        if event == "beforetool":
            out: dict[str, Any] = {"decision": "allow" if allow else "deny"}
            if not allow:
                out["reason"] = _DENIAL_MESSAGE
            return out
        return {}


class _AntigravityAdapter(ProviderAdapter):
    sources = ("antigravity",)

    def normalize_payload(self, payload: dict[str, Any], event_arg: str) -> None:
        if "hook_event_name" not in payload and event_arg:
            payload["hook_event_name"] = event_arg
        elif "hook_event_name" not in payload:
            payload["hook_event_name"] = self._infer_event(payload)

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

    def _infer_event(self, payload: dict[str, Any]) -> str:
        if "event" in payload:
            return str(payload["event"])
        if "toolCall" in payload:
            return "PreToolUse"
        if "tool_response" in payload or "error" in payload:
            return "PostToolUse"
        if "initialNumSteps" in payload:
            return "PreInvocation"
        return "PermissionRequest"

    def final_output(self, event: str, decision: str) -> dict[str, Any]:
        if decision == "pass":
            return {"decision": "ask"} if event == "pretooluse" else {}
        allow = decision == "approved"
        if event == "pretooluse":
            out: dict[str, Any] = {"decision": "allow" if allow else "deny"}
            if not allow:
                out["reason"] = _DENIAL_MESSAGE
            return out
        return {}


_DEFAULT_ADAPTER = ProviderAdapter()


def _get_adapter(source: str) -> ProviderAdapter:
    return ProviderAdapter._registry.get(source, _DEFAULT_ADAPTER)


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
    set_if_present("terminal_manager_session_title", "TERM_MANAGER_SESSION_TITLE", "")
    # Never trust a provider-supplied ownership marker. Only the explicit Codex
    # launcher environment may delegate approval handling back to Codex.
    payload.pop(_APPROVAL_OWNER_FIELD, None)
    if cli_source_arg == "codex" and os.environ.get(_APPROVAL_OWNER_ENV) == "codex":
        payload[_APPROVAL_OWNER_FIELD] = "codex"
    payload["cli_source"] = cli_source_arg
    _get_adapter(cli_source_arg).normalize_payload(payload, event_arg)
    return payload


def event_name(payload: dict[str, Any]) -> str:
    if "hook_event_name" in payload:
        return str(payload["hook_event_name"])
    if "event" in payload:
        return str(payload["event"])
    return "PermissionRequest"


def prefilter_response(event: str) -> str | None:
    if _normalize_event(event) in _PASSIVE_EVENTS_NORMALIZED:
        return None
    return '{"continue":true,"suppressOutput":true}'


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
    if provider_output:
        return provider_output
    return _get_adapter(cli_source).final_output(event, decision)


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

    suppressed = prefilter_response(event)

    session_id = str(payload.get("session_id") or "")[:8]
    log(f"Event: {event} session={session_id} source={cli_source}")
    event = norm_event

    if suppressed:
        log(f"Passive event suppressed before app: {event}")
        print(suppressed)
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
