#!/usr/bin/env python3
"""Hook-installer logic extracted verbatim from install-bridge.sh.

각 provider는 서브커맨드로 호출되며, 예전 install-bridge.sh의 inline Python
블록과 바이트 단위로 동일한 출력을 낸다(순수 이동 — scripts/test_install_hooks.py의
골든이 이를 고정). 이벤트 목록·타임아웃·matcher는 아직 하드코딩 유지(매니페스트 구동
전환은 후속 PR2에서 semantic-equivalence 검증과 함께 진행).

Usage:
    install_hooks.py claude       <settings.json> <bridge_dest>
    install_hooks.py codex-hooks  <hooks.json>    <bridge_dest>
    install_hooks.py codex-config <config.toml>   <bridge_dest>
    install_hooks.py gemini       <settings.json> <bridge_dest>
    install_hooks.py antigravity  <hooks.json>    <bridge_dest> <legacy_hooks> <legacy_dir>
"""
import json
import os
import sys


def install_claude(path, bridge_path):
    bridge_command = f'"{bridge_path}" --source claude'

    with open(path) as f:
        data = json.load(f)

    data.setdefault('hooks', {})

    approval_config  = {"hooks": [{"type": "command", "command": bridge_command, "timeout": 86400}]}
    lifecycle_config = {"hooks": [{"type": "command", "command": bridge_command}]}

    def remove_bridge_hooks(entries):
        cleaned = []
        for entry in entries:
            sub_hooks = [h for h in entry.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
            if sub_hooks:
                updated = dict(entry)
                updated["hooks"] = sub_hooks
                cleaned.append(updated)
        return cleaned

    for key, config in [
        ('SessionStart',      lifecycle_config),
        ('SessionEnd',        lifecycle_config),
        ('Notification',      lifecycle_config),
        ('Stop',              lifecycle_config),
        ('PreToolUse',        lifecycle_config),
        ('PostToolUse',       lifecycle_config),
        ('PostToolUseFailure', lifecycle_config),
        ('UserPromptSubmit',  lifecycle_config),
        ('Elicitation',       lifecycle_config),
        ('PermissionRequest', approval_config),
    ]:
        data['hooks'].setdefault(key, [])
        data['hooks'][key] = remove_bridge_hooks(data['hooks'][key])
        data['hooks'][key].append(config)

    for key in ['SubagentStop', 'PreCompact', 'StopFailure']:
        entries = remove_bridge_hooks(data['hooks'].get(key, []))
        if entries:
            data['hooks'][key] = entries
        else:
            data['hooks'].pop(key, None)

    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def install_codex_hooks(path, bridge_path):
    bridge_command = f'"{bridge_path}" --source codex'

    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            pass

    data.setdefault('hooks', {})

    # 공식 JSON 규격: {"EventName": [{"matcher": "*", "hooks": [{"type": "command", "command": "..."}]}]}
    events_lifecycle = ["SessionStart", "PostToolUse", "Stop"]
    events_status = ["PreToolUse"]
    events_approval = ["PermissionRequest"]
    retired_events = ["SessionEnd"]

    for event in events_lifecycle + events_status + events_approval:
        event_configs = data['hooks'].get(event, [])
        if not isinstance(event_configs, list):
            event_configs = []

        # PermissionRequest만 실제 승인 대기 이벤트이므로 타임아웃을 길게 설정함 (86400초 = 24시간)
        h_cmd = {"type": "command", "command": bridge_command}
        if event in events_approval:
            h_cmd["timeout"] = 86400

        found = False
        for config in event_configs:
            if config.get("matcher") == "*":
                sub_hooks = config.get("hooks", [])
                sub_hooks = [h for h in sub_hooks if "devisland-bridge.sh" not in h.get("command", "")]
                sub_hooks.append(h_cmd)
                config["hooks"] = sub_hooks
                found = True
                break

        if not found:
            event_configs.append({
                "matcher": "*",
                "hooks": [h_cmd]
            })

        data['hooks'][event] = event_configs

    for event in retired_events:
        cleaned = []
        for config in data['hooks'].get(event, []):
            sub_hooks = [h for h in config.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
            if sub_hooks:
                updated = dict(config)
                updated["hooks"] = sub_hooks
                cleaned.append(updated)
        if cleaned:
            data['hooks'][event] = cleaned
        else:
            data['hooks'].pop(event, None)

    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def patch_codex_config(path, bridge_path):
    lines = []
    if os.path.exists(path):
        with open(path, 'r') as f:
            lines = f.readlines()

    new_lines = []
    skip = False
    for line in lines:
        strip_line = line.strip()
        # 구형 [[hooks.]] 또는 [hooks] 섹션 제거 (hooks.json으로 일원화)
        if strip_line.startswith('[hooks]') or strip_line.startswith('[[hooks.'):
            skip = True
            continue
        if skip and strip_line.startswith('[') and not strip_line.startswith('[[hooks.'):
            skip = False
        if not skip:
            new_lines.append(line)

    # [features] 섹션 안에서 hooks feature flag를 활성화하고 deprecated codex_hooks는 제거
    features_idx = None
    for i, line in enumerate(new_lines):
        if line.strip() == '[features]':
            features_idx = i
            break

    if features_idx is not None:
        features_end = features_idx + 1
        while features_end < len(new_lines):
            if new_lines[features_end].strip().startswith('['):
                break
            features_end += 1

        found_hooks = False
        feature_lines = []
        for line in new_lines[features_idx + 1:features_end]:
            stripped = line.strip()
            key = stripped.split('=', 1)[0].strip() if '=' in stripped else ''
            if key == 'hooks':
                feature_lines.append('hooks = true\n')
                found_hooks = True
            elif key == 'codex_hooks':
                continue
            else:
                feature_lines.append(line)

        if not found_hooks:
            feature_lines.append('hooks = true\n')

        new_lines = new_lines[:features_idx + 1] + feature_lines + new_lines[features_end:]
    else:
        if new_lines and not new_lines[-1].endswith('\n'):
            new_lines.append('\n')
        new_lines.append('\n[features]\nhooks = true\n')

    with open(path, 'w') as f:
        f.writelines(new_lines)


def install_gemini(path, bridge_path):
    bridge_command = f'"{bridge_path}" --source gemini'

    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            pass

    hooks = data.get('hooks', {})
    if not isinstance(hooks, dict):
        hooks = {}

    for event in ["BeforeTool", "SessionStart", "SessionEnd", "AfterAgent", "Notification"]:
        event_configs = hooks.get(event, [])
        if not isinstance(event_configs, list):
            event_configs = []

        found = False
        for config in event_configs:
            if config.get("matcher") == "*":
                sub_hooks = config.get("hooks", [])
                sub_hooks = [h for h in sub_hooks if "devisland-bridge.sh" not in h.get("command", "")]
                hook_entry = {"type": "command", "command": bridge_command}
                if event == "BeforeTool":
                    hook_entry["timeout"] = 86400000
                sub_hooks.append(hook_entry)
                config["hooks"] = sub_hooks
                found = True
                break

        if not found:
            hook_entry = {"type": "command", "command": bridge_command}
            if event == "BeforeTool":
                hook_entry["timeout"] = 86400000
            event_configs.append({
                "matcher": "*",
                "hooks": [hook_entry]
            })

        hooks[event] = event_configs

    for event in ["AfterTool", "BeforeAgent", "BeforeModel", "BeforeToolSelection", "AfterModel", "PreCompress"]:
        cleaned = []
        for config in hooks.get(event, []):
            sub_hooks = [h for h in config.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
            if sub_hooks:
                updated = dict(config)
                updated["hooks"] = sub_hooks
                cleaned.append(updated)
        if cleaned:
            hooks[event] = cleaned
        else:
            hooks.pop(event, None)

    data['hooks'] = hooks

    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def install_antigravity(path, bridge_path, legacy_path, legacy_dir):
    same_hooks_file = (
        os.path.exists(path)
        and os.path.exists(legacy_path)
        and os.path.samefile(path, legacy_path)
    )

    def bridge_command(event):
        return f'"{bridge_path}" --source antigravity --event {event}'

    def is_bridge_command(command):
        return "devisland-bridge.sh" in command or "devisland-bridge-antigravity.sh" in command

    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = json.load(f)

    devisland_config = data.setdefault('devisland', {})
    devisland_config['enabled'] = True

    events_matcher_based = ["PreToolUse", "PostToolUse"]
    events_direct = ["PreInvocation", "PostInvocation", "Stop"]

    for event in events_matcher_based:
        event_configs = devisland_config.get(event, [])
        if not isinstance(event_configs, list):
            event_configs = []

        h_cmd = {"type": "command", "command": bridge_command(event)}
        if event == "PreToolUse":
            h_cmd["timeout"] = 86400

        found = False
        for config in event_configs:
            if config.get("matcher") == "*":
                sub_hooks = config.get("hooks", [])
                sub_hooks = [h for h in sub_hooks if not is_bridge_command(h.get("command", ""))]
                sub_hooks.append(h_cmd)
                config["hooks"] = sub_hooks
                found = True
                break

        if not found:
            event_configs.append({
                "matcher": "*",
                "hooks": [h_cmd]
            })
        devisland_config[event] = event_configs

    for event in events_direct:
        event_configs = devisland_config.get(event, [])
        if not isinstance(event_configs, list):
            event_configs = []

        event_configs = [h for h in event_configs if not is_bridge_command(h.get("command", ""))]
        h_cmd = {"type": "command", "command": bridge_command(event)}
        event_configs.append(h_cmd)
        devisland_config[event] = event_configs

    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    if os.path.exists(legacy_path) and not same_hooks_file:
        try:
            with open(legacy_path) as f:
                legacy_data = json.load(f)
            legacy_data.pop("devisland", None)
            with open(legacy_path, "w") as f:
                json.dump(legacy_data, f, indent=2, ensure_ascii=False)
        except Exception:
            pass

    for name in ["devisland-bridge-antigravity.sh", "devisland_bridge.py", "hook_events.json"]:
        try:
            os.remove(os.path.join(legacy_dir, name))
        except FileNotFoundError:
            pass


def main(argv):
    if len(argv) < 2:
        print("usage: install_hooks.py <provider> <args...>", file=sys.stderr)
        return 2

    provider = argv[1]
    dispatch = {
        "claude":       (install_claude,      2),
        "codex-hooks":  (install_codex_hooks, 2),
        "codex-config": (patch_codex_config,  2),
        "gemini":       (install_gemini,      2),
        "antigravity":  (install_antigravity, 4),
    }

    if provider not in dispatch:
        print(f"unknown provider: {provider}", file=sys.stderr)
        return 2

    func, argc = dispatch[provider]
    args = argv[2:]
    if len(args) != argc:
        print(f"{provider}: expected {argc} argument(s), got {len(args)}", file=sys.stderr)
        return 2

    func(*args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
