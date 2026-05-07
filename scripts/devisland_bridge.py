#!/usr/bin/env python3
"""DevIsland hook bridge payload processing and TCP transport."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from datetime import datetime
from typing import Any


LOG_PATH = "/tmp/DevIsland.bridge.log"
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


def log(message: str) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] {message}\n")


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
    payload["cli_source"] = cli_source_arg
    return payload


def event_name(payload: dict[str, Any]) -> str:
    return str(payload.get("hook_event_name", payload.get("event", "PermissionRequest")))


def send_to_app(payload: dict[str, Any]) -> str:
    encoded = dump(payload).encode("utf-8")
    with socket.create_connection(("127.0.0.1", 9090), timeout=5) as sock:
        sock.settimeout(300)
        sock.sendall(encoded)
        sock.shutdown(socket.SHUT_WR)

        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)

    return b"".join(chunks).decode("utf-8", errors="replace")


def response_result(raw: str) -> str:
    try:
        return str(json.loads(raw).get("response", "pass"))
    except Exception:
        return "pass"


def final_output(*, event: str, result: str, cli_source: str) -> dict[str, Any]:
    message = "DevIsland에서 거절되었습니다."

    if result == "pass":
        if cli_source == "claude":
            return {"continue": True, "suppressOutput": True}
        return {}

    allow = result == "approved"
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
        # PermissionRequest는 아래의 글로벌 핸들러에서 공통 처리하도록 함
        if event != "PermissionRequest":
            return {"continue": True}

    if event == "PermissionRequest" and result in ("approved", "denied"):
        decision: dict[str, Any] = {"behavior": "allow" if result == "approved" else "deny"}
        if result != "approved":
            decision["message"] = message
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        }

    return {"continue": True, "suppressOutput": True}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="")
    args = parser.parse_args()

    cli_source = args.source or "claude"
    payload = enrich_payload(load_payload(), cli_source)
    event = event_name(payload)

    log(f"Raw Payload: {dump(payload)}")
    log(f"Event Detected: {event} (Source: {cli_source})")

    if event not in PASSIVE_EVENTS:
        log(f"Passive event suppressed before app: {event}")
        print('{"continue":true,"suppressOutput":true}')
        return 0

    try:
        raw = send_to_app(payload)
        log(f"Raw Response: {raw}")
        result = response_result(raw)
    except Exception as error:
        log(f"Bridge transport error: {error}")
        result = "pass"

    log(f"Result: {result}")

    output = final_output(event=event, result=result, cli_source=cli_source)
    final = dump(output)
    log(f"Final Output: {final}")
    print(final)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
