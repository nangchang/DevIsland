#!/usr/bin/env python3
"""Hook-installer logic — single source of truth for hook installation.

앱(BridgeInstaller)과 install-bridge.sh가 공통으로 호출한다. 각 provider는
서브커맨드로 호출된다. claude/codex의 이벤트 이름 membership은 hook_events.json
매니페스트에서 읽어 런타임 브리지(devisland_bridge.py)와 단일 소스를 공유한다.
gemini/antigravity는 config 형태 축(matcher-기반 vs direct-list)이 매니페스트의
active/lifecycle 축과 어긋나 하드코딩을 유지한다(config 형태·타임아웃·matcher는
어느 provider든 여기 코드에 남는다 — 매니페스트는 membership만 제공).

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

# 매니페스트는 이 스크립트와 같은 디렉토리에 있다(scripts/ 또는 앱 Resources/).
MANIFEST_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook_events.json")


def _manifest_provider(name):
    """hook_events.json에서 provider의 (lifecycle, active, retired) 이벤트 목록을 읽는다."""
    with open(MANIFEST_PATH, encoding="utf-8") as f:
        manifest = json.load(f)
    prov = manifest.get(name)
    if not isinstance(prov, dict):
        raise SystemExit(f"install_hooks: manifest에 provider '{name}' 없음 ({MANIFEST_PATH})")
    return (
        prov.get("lifecycle", []),
        prov.get("active", []),
        prov.get("retired", []),
    )


def install_claude(path, bridge_path):
    bridge_command = f'"{bridge_path}" --source claude'
    lifecycle, active, retired = _manifest_provider("claude")

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

    # 매니페스트: lifecycle 이벤트는 기본 config, active(승인) 이벤트는 긴 타임아웃 config.
    entries = [(key, lifecycle_config) for key in lifecycle] + \
              [(key, approval_config) for key in active]
    for key, config in entries:
        data['hooks'].setdefault(key, [])
        data['hooks'][key] = remove_bridge_hooks(data['hooks'][key])
        data['hooks'][key].append(config)

    for key in retired:
        entries = remove_bridge_hooks(data['hooks'].get(key, []))
        if entries:
            data['hooks'][key] = entries
        else:
            data['hooks'].pop(key, None)

    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def install_codex_hooks(path, bridge_path):
    bridge_command = f'"{bridge_path}" --source codex'
    lifecycle, active, retired_events = _manifest_provider("codex")

    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            pass

    data.setdefault('hooks', {})

    # 공식 JSON 규격: {"EventName": [{"matcher": "*", "hooks": [{"type": "command", "command": "..."}]}]}
    for event in lifecycle + active:
        event_configs = data['hooks'].get(event, [])
        if not isinstance(event_configs, list):
            event_configs = []

        # active(승인 대기) 이벤트만 타임아웃을 길게 설정함 (86400초 = 24시간)
        h_cmd = {"type": "command", "command": bridge_command}
        if event in active:
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
