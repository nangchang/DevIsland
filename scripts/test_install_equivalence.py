#!/usr/bin/env python3
"""R5-c PR2 마이그레이션 증명 — install_hooks.py ≈ (구) Swift BridgeInstaller.

앱(BridgeInstaller)이 자체 Swift patch 함수 대신 install_hooks.py를 subprocess로
호출하도록 전환하기 전에, 삭제 대상이던 Swift patch 함수의 출력을
fixtures/install_hooks/swift_old/에 캡처했다(HEAD의 BridgeEquivalenceCaptureTests).
이 테스트는 install_hooks.py의 출력이 그 Swift 출력과 **의미적으로 동치**임을 고정한다.

바이트 동치가 아니라 의미 동치인 이유: Swift는 JSONSerialization(.sortedKeys)로
`"a" : "\/x"`처럼 콜론 앞 공백·슬래시 이스케이프를 넣고, Python은 json.dumps로
`"a": "/x"`를 낸다 — 파싱하면 동일한 객체다. codex config.toml은 라인 기반이라
빈 줄 cosmetic 차이(빈 입력 시 Swift가 선두 빈 줄 1개 더 생성)만 있어, 의미 있는
(non-blank) 라인 시퀀스로 비교한다.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INSTALLER = ROOT / "install_hooks.py"
INPUTS = ROOT / "fixtures" / "install_hooks" / "inputs"
SWIFT_OLD = ROOT / "fixtures" / "install_hooks" / "swift_old"
BRIDGE = "/BRIDGE"  # Swift 캡처와 동일한 결정적 bridge 경로

# (subcommand, fixture_basename) — antigravity는 legacy 인자 2개 추가
JSON_CASES = [
    ("claude", "claude_empty.json"),
    ("claude", "claude_full.json"),
    ("codex-hooks", "codex_hooks_empty.json"),
    ("codex-hooks", "codex_hooks_full.json"),
    ("gemini", "gemini_empty.json"),
    ("gemini", "gemini_full.json"),
    ("antigravity", "antigravity_empty.json"),
    ("antigravity", "antigravity_full.json"),
]
TOML_CASES = [
    ("codex-config", "codex_config_empty.toml"),
    ("codex-config", "codex_config_full.toml"),
]


def _run(subcommand: str, work: Path, tmp: Path) -> None:
    args = [sys.executable, str(INSTALLER), subcommand, str(work), BRIDGE]
    if subcommand == "antigravity":
        args += [str(tmp / "legacy_missing.json"), str(tmp / "legacy_dir")]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"{subcommand} {work.name} 실패: {result.stderr}")


class InstallEquivalenceTest(unittest.TestCase):
    def test_json_semantic_equivalence(self) -> None:
        for subcommand, fixture in JSON_CASES:
            with self.subTest(fixture=fixture):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    work = tmp_path / fixture
                    shutil.copy(INPUTS / fixture, work)
                    _run(subcommand, work, tmp_path)

                    produced = json.loads(work.read_text(encoding="utf-8"))
                    swift_old = json.loads((SWIFT_OLD / fixture).read_text(encoding="utf-8"))
                    self.assertEqual(
                        produced, swift_old,
                        msg=f"{fixture}: Python 출력이 (구) Swift 출력과 의미적으로 다름",
                    )

    def test_toml_semantic_equivalence(self) -> None:
        """config.toml은 라인 기반 — 의미 있는(non-blank) 라인 시퀀스로 비교한다."""
        def meaningful(text: str) -> list[str]:
            return [ln.rstrip() for ln in text.splitlines() if ln.strip()]

        for subcommand, fixture in TOML_CASES:
            with self.subTest(fixture=fixture):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    work = tmp_path / fixture
                    shutil.copy(INPUTS / fixture, work)
                    _run(subcommand, work, tmp_path)

                    produced = meaningful(work.read_text(encoding="utf-8"))
                    swift_old = meaningful((SWIFT_OLD / fixture).read_text(encoding="utf-8"))
                    self.assertEqual(
                        produced, swift_old,
                        msg=f"{fixture}: Python config.toml이 (구) Swift와 의미적으로 다름",
                    )


if __name__ == "__main__":
    unittest.main()
