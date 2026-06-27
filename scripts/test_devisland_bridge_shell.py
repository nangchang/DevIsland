#!/usr/bin/env python3
"""Regression tests for devisland-bridge.sh terminal source detection."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "scripts" / "devisland-bridge.sh"


class BridgeShellTest(unittest.TestCase):
    def run_bridge(self, env: dict[str, str], fake_bins: dict[str, str]) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            script_dir = tmp_path / "bridge"
            bin_dir.mkdir()
            script_dir.mkdir()

            shutil.copy(BRIDGE, script_dir / "devisland-bridge.sh")
            (script_dir / "devisland_bridge.py").write_text("# fake helper placeholder\n", encoding="utf-8")

            capture_path = tmp_path / "capture.json"
            fake_python = f"""
            #!/bin/sh
            cat > /dev/null
            printf '{{"TERM_APP":"%s","TERM_TITLE":"%s","TERM_TTY":"%s","TERM_WINDOW_ID":"%s","TERM_TMUX_PANE":"%s","TERM_TMUX_SOCKET":"%s","TERM_TMUX_CLIENT":"%s","TERM_MANAGER_SESSION_TITLE":"%s"}}\\n' \\
              "$TERM_APP" "$TERM_TITLE" "$TERM_TTY" "$TERM_WINDOW_ID" "$TERM_TMUX_PANE" "$TERM_TMUX_SOCKET" "$TERM_TMUX_CLIENT" "$TERM_MANAGER_SESSION_TITLE" > "{capture_path}"
            printf '{{}}\\n'
            """
            fake_bins = {**fake_bins, "python3": textwrap.dedent(fake_python)}
            for name, body in fake_bins.items():
                path = bin_dir / name
                path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IXUSR)

            run_env = os.environ.copy()
            for key in ("TERM_PROGRAM", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "TMUX", "TMUX_PANE"):
                run_env.pop(key, None)
            run_env.update(env)
            run_env["PATH"] = f"{bin_dir}:{run_env.get('PATH', '')}"

            proc = subprocess.run(
                [str(script_dir / "devisland-bridge.sh"), "--source", "claude"],
                input=json.dumps({"hook_event_name": "SessionStart", "session_id": "s1", "cwd": str(ROOT)}),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=str(ROOT),
                env=run_env,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(capture_path.exists(), f"helper was not invoked; stdout={proc.stdout!r}")
            return json.loads(capture_path.read_text(encoding="utf-8"))

    def test_plain_wezterm_is_forwarded_as_terminal_source(self):
        captured = self.run_bridge(
            env={
                "TERM_PROGRAM": "WezTerm",
                "WEZTERM_PANE": "0",
                "WEZTERM_UNIX_SOCKET": "/tmp/wezterm-sock",
            },
            fake_bins={
                "tty": "#!/bin/sh\nprintf '/dev/ttys008\\n'\n",
            },
        )

        self.assertEqual(captured["TERM_APP"], "WezTerm")
        self.assertEqual(captured["TERM_TTY"], "/dev/ttys008")
        self.assertEqual(captured["TERM_WINDOW_ID"], "0")
        self.assertEqual(captured["TERM_TMUX_PANE"], "")

    def test_plain_wezterm_takes_precedence_over_cmux_environment(self):
        captured = self.run_bridge(
            env={
                "TERM_PROGRAM": "WezTerm",
                "WEZTERM_PANE": "12",
                "CMUX_WORKSPACE_ID": "workspace-1",
                "CMUX_SURFACE_ID": "surface-1",
            },
            fake_bins={
                "tty": "#!/bin/sh\nprintf '/dev/ttys011\\n'\n",
                "osascript": "#!/bin/sh\nprintf 'true\\n'\n",
            },
        )

        self.assertEqual(captured["TERM_APP"], "WezTerm")
        self.assertEqual(captured["TERM_TTY"], "/dev/ttys011")
        self.assertEqual(captured["TERM_WINDOW_ID"], "12")

    def test_wezterm_tmux_client_is_forwarded_as_terminal_source(self):
        captured = self.run_bridge(
            env={
                "TERM_PROGRAM": "tmux",
                "TMUX": "/private/tmp/tmux-501/default,2797,2",
                "TMUX_PANE": "%9",
            },
            fake_bins={
                "tty": "#!/bin/sh\nprintf '/dev/ttys009\\n'\n",
                "tmux": """
                    #!/bin/sh
                    if [ "$1" = "list-clients" ] && [ "$3" = '#{client_name}|#{client_tty}|#{pane_id}' ]; then
                      printf '/dev/ttys000|/dev/ttys000|%%8\\n'
                      printf '/dev/ttys008|/dev/ttys008|%%9\\n'
                    elif [ "$1" = "list-clients" ] && [ "$3" = '#{client_tty}|#{client_pid}' ]; then
                      printf '/dev/ttys000|44313\\n'
                      printf '/dev/ttys008|13049\\n'
                    elif [ "$1" = "display-message" ] && [ "$3" = '#{client_tty}' ]; then
                      printf '/dev/ttys008\\n'
                    elif [ "$1" = "display-message" ] && [ "$3" = '#{client_name}' ]; then
                      printf '/dev/ttys008\\n'
                    fi
                """,
                "ps": """
                    #!/bin/sh
                    field="$2"
                    pid="$4"
                    if [ "$field" = "comm=" ]; then
                      case "$pid" in
                        13049) printf 'tmux\\n' ;;
                        44306) printf '/Applications/WezTerm.app/Contents/MacOS/wezterm-gui\\n' ;;
                        *) printf 'launchd\\n' ;;
                      esac
                    elif [ "$field" = "ppid=" ]; then
                      case "$pid" in
                        13049) printf '44306\\n' ;;
                        44306) printf '1\\n' ;;
                        *) printf '0\\n' ;;
                      esac
                    elif [ "$field" = "tty=" ]; then
                      printf 'ttys009\\n'
                    fi
                """,
                "osascript": "#!/bin/sh\nprintf 'false\\n'\n",
            },
        )

        self.assertEqual(captured["TERM_APP"], "WezTerm")
        self.assertEqual(captured["TERM_TTY"], "/dev/ttys008")
        self.assertEqual(captured["TERM_TMUX_PANE"], "%9")
        self.assertEqual(captured["TERM_TMUX_CLIENT"], "/dev/ttys008")

    def test_prefilter_suppression_skips_terminal_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            script_dir = tmp_path / "bridge"
            bin_dir.mkdir()
            script_dir.mkdir()

            shutil.copy(BRIDGE, script_dir / "devisland-bridge.sh")
            (script_dir / "devisland_bridge.py").write_text("# fake helper placeholder\n", encoding="utf-8")
            detection_marker = tmp_path / "detection-called"
            helper_marker = tmp_path / "helper-called"

            fake_python = f"""
            #!/bin/sh
            touch "{helper_marker}"
            cat > /dev/null
            printf '{{}}\\n'
            """
            fake_tty = f"""
            #!/bin/sh
            touch "{detection_marker}"
            printf '/dev/ttys008\\n'
            """
            for name, body in {"python3": fake_python, "tty": fake_tty}.items():
                path = bin_dir / name
                path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IXUSR)

            run_env = os.environ.copy()
            run_env["PATH"] = f"{bin_dir}:{run_env.get('PATH', '')}"
            proc = subprocess.run(
                [str(script_dir / "devisland-bridge.sh"), "--source", "claude", "--event", "UnknownEvent"],
                input=json.dumps({"hook_event_name": "UnknownEvent", "session_id": "s1"}),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=str(ROOT),
                env=run_env,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout), {"continue": True, "suppressOutput": True})
            self.assertFalse(detection_marker.exists(), "terminal detection ran despite prefilter suppression")
            self.assertFalse(helper_marker.exists(), "normal helper path ran despite prefilter suppression")

    def test_prefilter_for_forwarded_event_invokes_python_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            script_dir = tmp_path / "bridge"
            bin_dir.mkdir()
            script_dir.mkdir()

            shutil.copy(BRIDGE, script_dir / "devisland-bridge.sh")
            (script_dir / "devisland_bridge.py").write_text("# fake helper placeholder\n", encoding="utf-8")
            python_count = tmp_path / "python-count"

            fake_python = f"""
            #!/bin/sh
            current=0
            [ -f "{python_count}" ] && current=$(cat "{python_count}")
            current=$((current + 1))
            printf '%s\\n' "$current" > "{python_count}"
            cat > /dev/null
            printf '{{}}\\n'
            """
            for name, body in {
                "python3": fake_python,
                "tty": "#!/bin/sh\nprintf '/dev/ttys008\\n'\n",
            }.items():
                path = bin_dir / name
                path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IXUSR)

            run_env = os.environ.copy()
            run_env["TERM_PROGRAM"] = "WezTerm"
            run_env["PATH"] = f"{bin_dir}:{run_env.get('PATH', '')}"
            proc = subprocess.run(
                [str(script_dir / "devisland-bridge.sh"), "--source", "antigravity", "--event", "PreToolUse"],
                input=json.dumps({"conversationId": "s1", "toolCall": {"name": "run_command"}}),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=str(ROOT),
                env=run_env,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, "{}\n")
            self.assertEqual(python_count.read_text(encoding="utf-8").strip(), "1")

    def test_shell_prefilter_events_match_manifest(self):
        bridge_text = BRIDGE.read_text(encoding="utf-8")
        start = bridge_text.index("case \"$NORM_EVENT\" in")
        end = bridge_text.index("*)", start)
        case_lines = bridge_text[start:end].splitlines()[1:]
        raw_events = "".join(line.strip() for line in case_lines).replace(";;", "").rstrip(")")
        shell_events = set(raw_events.split("|"))

        manifest = json.loads((ROOT / "scripts" / "hook_events.json").read_text(encoding="utf-8"))
        manifest_events: set[str] = set()
        for key, value in manifest.items():
            if key.startswith("_"):
                manifest_events.update(value)
            else:
                manifest_events.update(value.get("active", []))
                manifest_events.update(value.get("lifecycle", []))
        normalized_manifest = {
            event.lower().replace("_", "").replace("-", "")
            for event in manifest_events
        }

        self.assertEqual(shell_events, normalized_manifest)

    def test_detached_aoe_tmux_session_forwards_manager_title(self):
        captured = self.run_bridge(
            env={
                "TERM_PROGRAM": "tmux",
                "TMUX": "/private/tmp/tmux-501/default,2797,2",
                "TMUX_PANE": "%12",
            },
            fake_bins={
                "tty": "#!/bin/sh\nprintf '/dev/ttys999\\n'\n",
                "tmux": """
                    #!/bin/sh
                    if [ "$1" = "display-message" ] && [ "$3" = '#{session_name}' ]; then
                      printf 'aoe_Bohemians_abc123\\n'
                    fi
                """,
                "pgrep": """
                    #!/bin/sh
                    if [ "$1" = "-nx" ] && [ "$2" = "aoe" ]; then
                      printf '4321\\n'
                    fi
                """,
                "ps": """
                    #!/bin/sh
                    field="$2"
                    pid="$4"
                    if [ "$field" = "tty=" ] && [ "$pid" = "4321" ]; then
                      printf 'ttys012\\n'
                    elif [ "$field" = "comm=" ]; then
                      case "$pid" in
                        4321) printf '/opt/homebrew/bin/aoe\\n' ;;
                        5000) printf '/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal\\n' ;;
                        *) printf 'launchd\\n' ;;
                      esac
                    elif [ "$field" = "ppid=" ]; then
                      case "$pid" in
                        4321) printf '5000\\n' ;;
                        5000) printf '1\\n' ;;
                        *) printf '0\\n' ;;
                      esac
                    fi
                """,
                "osascript": """
                    #!/bin/sh
                    if [ "$1" = "-e" ]; then
                      case "$2" in
                        *iTerm*) printf 'false\\n' ;;
                        *Terminal*) printf 'true\\n' ;;
                        *) printf 'false\\n' ;;
                      esac
                    else
                      cat > /dev/null
                      printf 'Terminal:::42:::1\\n'
                    fi
                """,
            },
        )

        self.assertEqual(captured["TERM_APP"], "Terminal")
        self.assertEqual(captured["TERM_TTY"], "/dev/ttys012")
        self.assertEqual(captured["TERM_TMUX_PANE"], "%12")
        self.assertEqual(captured["TERM_MANAGER_SESSION_TITLE"], "Bohemians")


if __name__ == "__main__":
    unittest.main()
