#!/usr/bin/env python3
"""Golden regression tests for install_hooks.py.

install_hooks.py는 install-bridge.sh의 inline Python 블록을 순수 이동한 것이므로,
이 테스트는 provider별 입력(빈 설정 + 이미 훅이 있는 non-empty 설정)에 대해 출력이
커밋된 골든과 바이트 단위로 동일한지 확인한다. 골든은 이동 직전 inline Python 출력을
캡처한 것. non-empty 케이스는 stale devisland 훅 제거·외부 훅 보존·retired 이벤트 정리
분기를 실제로 태운다(빈 입력만으론 이 분기들이 커버되지 않음).
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INSTALLER = ROOT / "install_hooks.py"
FIXTURES = ROOT / "fixtures" / "install_hooks"
INPUTS = FIXTURES / "inputs"
GOLDEN = FIXTURES / "golden"
BRIDGE = "/BRIDGE"  # 골든 캡처 시 사용한 결정적 bridge 경로

# (provider, fixture_basename, extra_arg_count) — antigravity는 legacy 인자 2개 추가
CASES = [
    ("claude", "claude_empty.json", 0),
    ("claude", "claude_full.json", 0),
    ("codex-hooks", "codex_hooks_empty.json", 0),
    ("codex-hooks", "codex_hooks_full.json", 0),
    ("codex-config", "codex_config_empty.toml", 0),
    ("codex-config", "codex_config_full.toml", 0),
    ("gemini", "gemini_empty.json", 0),
    ("gemini", "gemini_full.json", 0),
    ("antigravity", "antigravity_empty.json", 2),
    ("antigravity", "antigravity_full.json", 2),
]


class InstallHooksGoldenTest(unittest.TestCase):
    def _run_case(self, provider: str, fixture: str, extra: int) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            work = tmp_path / fixture
            shutil.copy(INPUTS / fixture, work)

            args = [sys.executable, str(INSTALLER), provider, str(work), BRIDGE]
            if extra == 2:
                # legacy_hooks(존재하지 않음) + legacy_dir — 골든 캡처와 동일 조건
                args += [str(tmp_path / "legacy_missing.json"), str(tmp_path / "legacy_dir")]

            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(
                result.returncode, 0,
                msg=f"{provider} {fixture} 실패: {result.stderr}",
            )

            produced = work.read_text(encoding="utf-8")
            expected = (GOLDEN / fixture).read_text(encoding="utf-8")
            self.assertEqual(
                produced, expected,
                msg=f"{provider} {fixture} 출력이 골든과 다름 (순수 이동 위반)",
            )

    def test_golden(self) -> None:
        for provider, fixture, extra in CASES:
            with self.subTest(provider=provider, fixture=fixture):
                self._run_case(provider, fixture, extra)

    def test_corrupt_json_fails_without_overwriting(self) -> None:
        """손상된 JSON 설정은 fail-fast하고 원본을 보존해야 한다.

        예전 inline Python은 파싱 실패를 삼키고 {}에서 재작성해 hooks 외
        사용자 설정(특히 gemini settings.json)을 유실시켰다.
        """
        corrupt = '{"hooks": broken'
        for provider in ["codex-hooks", "gemini"]:
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as tmp:
                    work = Path(tmp) / "config.json"
                    work.write_text(corrupt, encoding="utf-8")

                    result = subprocess.run(
                        [sys.executable, str(INSTALLER), provider, str(work), BRIDGE],
                        capture_output=True, text=True,
                    )

                    self.assertNotEqual(result.returncode, 0, msg=f"{provider}: 손상 JSON인데 성공")
                    self.assertIn("손상된 JSON", result.stderr)
                    self.assertEqual(
                        work.read_text(encoding="utf-8"), corrupt,
                        msg=f"{provider}: 손상 파일이 덮어써짐",
                    )

    def test_non_dict_json_fails_without_overwriting(self) -> None:
        """최상위가 객체가 아닌 JSON도 traceback 없이 명확한 오류로 실패해야 한다."""
        non_dict = '["not", "a", "dict"]'
        for provider in ["codex-hooks", "gemini"]:
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as tmp:
                    work = Path(tmp) / "config.json"
                    work.write_text(non_dict, encoding="utf-8")

                    result = subprocess.run(
                        [sys.executable, str(INSTALLER), provider, str(work), BRIDGE],
                        capture_output=True, text=True,
                    )

                    self.assertNotEqual(result.returncode, 0, msg=f"{provider}: 비객체 JSON인데 성공")
                    self.assertIn("JSON 객체가 아닙니다", result.stderr)
                    self.assertEqual(work.read_text(encoding="utf-8"), non_dict)

    def test_antigravity_legacy_cleanup(self) -> None:
        """레거시 hooks.json에서 devisland 키 제거 + 레거시 파일 삭제 분기.

        골든 케이스는 레거시 경로를 시딩하지 않아 이 파일-삭제 분기가 no-op으로 빠진다.
        파일을 지우는 코드이므로 여기서 명시적으로 태운다.
        """
        import json

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            hooks = tmp_path / "hooks.json"
            hooks.write_text("{}", encoding="utf-8")

            legacy_dir = tmp_path / "legacy"
            legacy_dir.mkdir()
            legacy = legacy_dir / "hooks.json"
            legacy.write_text(
                json.dumps({"devisland": {"enabled": True}, "keep": 1}),
                encoding="utf-8",
            )
            stray = ["devisland-bridge-antigravity.sh", "devisland_bridge.py", "hook_events.json"]
            for name in stray:
                (legacy_dir / name).write_text("x", encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(INSTALLER), "antigravity",
                 str(hooks), BRIDGE, str(legacy), str(legacy_dir)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)

            legacy_data = json.loads(legacy.read_text(encoding="utf-8"))
            self.assertNotIn("devisland", legacy_data)  # devisland 키 제거됨
            self.assertEqual(legacy_data.get("keep"), 1)  # 나머지 보존
            for name in stray:
                self.assertFalse((legacy_dir / name).exists(), f"{name} 미삭제")


if __name__ == "__main__":
    unittest.main()
