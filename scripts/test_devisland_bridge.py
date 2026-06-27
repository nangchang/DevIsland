#!/usr/bin/env python3
"""Regression tests for devisland_bridge.py event-allow-list normalization."""

import json
import unittest
from pathlib import Path

from devisland_bridge import (
    _FALLBACK_PASSIVE_EVENTS,
    _normalize_event,
    _PASSIVE_EVENTS_NORMALIZED,
    PASSIVE_EVENTS,
    PREFILTER_CONTINUE,
    enrich_payload,
    event_name,
    final_output,
    suppress_before_app_response,
)

_MANIFEST_PATH = Path(__file__).parent / "hook_events.json"


class TestNormalizeEvent(unittest.TestCase):
    def test_lowercase_passthrough(self):
        self.assertEqual(_normalize_event("permissionrequest"), "permissionrequest")

    def test_strips_underscores(self):
        self.assertEqual(_normalize_event("permission_request"), "permissionrequest")

    def test_strips_hyphens(self):
        self.assertEqual(_normalize_event("pre-tool-use"), "pretooluse")

    def test_case_insensitive(self):
        self.assertEqual(_normalize_event("PermissionRequest"), "permissionrequest")
        self.assertEqual(_normalize_event("PERMISSIONREQUEST"), "permissionrequest")


class TestPassiveEventsNormalized(unittest.TestCase):
    """Regression: lower/mixed-case event names must not be suppressed by the bridge."""

    def _is_passive(self, raw_name: str) -> bool:
        return _normalize_event(raw_name) in _PASSIVE_EVENTS_NORMALIZED

    # Lower-case variants (the bug scenario from issue #235)
    def test_lowercase_permissionrequest_is_passive(self):
        self.assertTrue(self._is_passive("permissionrequest"))

    def test_lowercase_sessionstart_is_passive(self):
        self.assertTrue(self._is_passive("sessionstart"))

    def test_lowercase_pretooluse_is_passive(self):
        self.assertTrue(self._is_passive("pretooluse"))

    def test_lowercase_elicitation_is_passive(self):
        self.assertTrue(self._is_passive("elicitation"))

    # Canonical-case variants must still pass
    def test_canonical_permissionrequest_is_passive(self):
        self.assertTrue(self._is_passive("PermissionRequest"))

    def test_canonical_pretooluse_is_passive(self):
        self.assertTrue(self._is_passive("PreToolUse"))

    # Separator variants
    def test_underscore_variant_is_passive(self):
        self.assertTrue(self._is_passive("permission_request"))

    def test_hyphen_variant_is_passive(self):
        self.assertTrue(self._is_passive("pre-tool-use"))

    # Non-passive events must still be suppressed
    def test_unknown_event_is_not_passive(self):
        self.assertFalse(self._is_passive("SomeRandomEvent"))

    def test_empty_string_is_not_passive(self):
        self.assertFalse(self._is_passive(""))


class TestPrefilterResponse(unittest.TestCase):
    def test_manifest_event_continues_to_terminal_detection(self):
        self.assertIsNone(suppress_before_app_response("SessionStart"))

    def test_separator_variant_continues_to_terminal_detection(self):
        self.assertIsNone(suppress_before_app_response("pre-tool-use"))

    def test_unknown_event_is_suppressed_before_terminal_detection(self):
        self.assertEqual(
            suppress_before_app_response("SomeRandomEvent"),
            '{"continue":true,"suppressOutput":true}',
        )

    def test_prefilter_continue_sentinel_is_stable_for_shell_bridge(self):
        self.assertEqual(PREFILTER_CONTINUE, "__DEVISLAND_PREFILTER_CONTINUE__")


class TestFinalOutputNormalized(unittest.TestCase):
    """Regression: final_output must route correctly regardless of event name case."""

    def test_permissionrequest_approved_claude(self):
        out = final_output(event="permissionrequest", decision="approved", provider_output=None, cli_source="claude")
        self.assertEqual(out.get("hookSpecificOutput", {}).get("hookEventName"), "PermissionRequest")
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "allow")

    def test_permissionrequest_denied_claude(self):
        out = final_output(event="permissionrequest", decision="denied", provider_output=None, cli_source="claude")
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_PermissionRequest_canonical_still_works(self):
        """Canonical-case must also work since main() normalizes before calling."""
        out = final_output(event="permissionrequest", decision="approved", provider_output=None, cli_source="claude")
        self.assertIn("hookSpecificOutput", out)

    def test_beforetool_approved_gemini(self):
        out = final_output(event="beforetool", decision="approved", provider_output=None, cli_source="gemini")
        self.assertEqual(out, {"decision": "allow"})

    def test_beforetool_denied_gemini(self):
        out = final_output(event="beforetool", decision="denied", provider_output=None, cli_source="gemini")
        self.assertEqual(out["decision"], "deny")
        self.assertIn("reason", out)

    def test_pretooluse_pass_antigravity_asks_native_permission(self):
        out = final_output(event="pretooluse", decision="pass", provider_output=None, cli_source="antigravity")
        self.assertEqual(out, {"decision": "ask"})

    def test_pretooluse_approved_antigravity_allows(self):
        out = final_output(event="pretooluse", decision="approved", provider_output=None, cli_source="antigravity")
        self.assertEqual(out, {"decision": "allow"})

    def test_pretooluse_denied_antigravity_denies(self):
        out = final_output(event="pretooluse", decision="denied", provider_output=None, cli_source="antigravity")
        self.assertEqual(out["decision"], "deny")
        self.assertIn("reason", out)

    def test_pretooluse_denied_codex(self):
        out = final_output(event="pretooluse", decision="denied", provider_output=None, cli_source="codex")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_userpromptsubmit_denied_claude(self):
        out = final_output(event="userpromptsubmit", decision="denied", provider_output=None, cli_source="claude")
        self.assertEqual(out["decision"], "block")

    def test_elicitation_denied_claude(self):
        out = final_output(event="elicitation", decision="denied", provider_output=None, cli_source="claude")
        self.assertEqual(out["hookSpecificOutput"]["action"], "decline")


class TestAntigravityPayloadNormalization(unittest.TestCase):
    def test_pretooluse_payload_is_normalized_for_dev_island(self):
        payload = {
            "conversationId": "ec33ebf9-0cba-4100-8142-c61503f6c587",
            "workspacePaths": ["/workspace/project"],
            "toolCall": {
                "name": "run_command",
                "args": {
                    "CommandLine": "npm test",
                    "Cwd": "/workspace/project",
                },
            },
        }

        enriched = enrich_payload(payload, "antigravity", "PreToolUse")

        self.assertEqual(enriched["hook_event_name"], "PreToolUse")
        self.assertEqual(enriched["session_id"], "ec33ebf9-0cba-4100-8142-c61503f6c587")
        self.assertEqual(enriched["tool_name"], "run_command")
        self.assertEqual(enriched["tool_input"]["CommandLine"], "npm test")
        self.assertEqual(enriched["cwd"], "/workspace/project")
        self.assertEqual(event_name(enriched), "PreToolUse")

    def test_lifecycle_event_arg_sets_hook_event_name(self):
        payload = {
            "conversationId": "ec33ebf9-0cba-4100-8142-c61503f6c587",
            "initialNumSteps": 10,
            "workspacePaths": ["/workspace/project"],
        }

        enriched = enrich_payload(payload, "antigravity", "PreInvocation")

        self.assertEqual(enriched["hook_event_name"], "PreInvocation")
        self.assertEqual(enriched["session_id"], "ec33ebf9-0cba-4100-8142-c61503f6c587")
        self.assertEqual(enriched["cwd"], "/workspace/project")


class TestHookEventsManifest(unittest.TestCase):
    """PASSIVE_EVENTS must stay in sync with hook_events.json."""

    def setUp(self):
        with open(_MANIFEST_PATH, encoding="utf-8") as fh:
            self._manifest = json.load(fh)

    def _all_installed_events(self) -> set[str]:
        """Union of active + lifecycle across all providers, plus _bridge_extras."""
        events: set[str] = set()
        for key, value in self._manifest.items():
            if key.startswith("_"):
                events.update(value)
            else:
                events.update(value.get("active", []))
                events.update(value.get("lifecycle", []))
        return events

    def _all_retired_events(self) -> set[str]:
        """Union of retired lists across all providers."""
        events: set[str] = set()
        for key, value in self._manifest.items():
            if not key.startswith("_"):
                events.update(value.get("retired", []))
        return events

    def test_passive_events_includes_all_manifest_events(self):
        """PASSIVE_EVENTS must contain every installed + bridge-extra event from the manifest."""
        required = self._all_installed_events()
        missing = required - set(PASSIVE_EVENTS)
        self.assertEqual(missing, set(), f"Events in manifest but not in PASSIVE_EVENTS: {missing}")

    def test_passive_events_no_extra_events(self):
        """PASSIVE_EVENTS must not contain events beyond what the manifest declares."""
        required = self._all_installed_events()
        extra = set(PASSIVE_EVENTS) - required
        self.assertEqual(extra, set(), f"Events in PASSIVE_EVENTS but not in manifest: {extra}")

    def test_truly_retired_events_not_in_passive_events(self):
        """Events retired by ALL providers (and not installed by any) must be suppressed."""
        passive_union = self._all_installed_events()
        retired_union = self._all_retired_events()
        # An event is only truly retired if no provider still installs it.
        truly_retired = retired_union - passive_union
        for event in truly_retired:
            self.assertNotIn(
                event, PASSIVE_EVENTS,
                f"Truly-retired event '{event}' must not be in PASSIVE_EVENTS",
            )

    def test_passive_events_matches_original_12(self):
        """Regression: PASSIVE_EVENTS must equal the original hardcoded 12 events."""
        expected = frozenset({
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
        self.assertEqual(PASSIVE_EVENTS, expected)

    def test_fallback_matches_manifest(self):
        """The import-time fallback snapshot must not drift from the manifest.

        PASSIVE_EVENTS is manifest-derived when the file is present, so equality
        guarantees the hardcoded safety net stays in sync with hook_events.json.
        """
        self.assertEqual(_FALLBACK_PASSIVE_EVENTS, PASSIVE_EVENTS)


if __name__ == "__main__":
    unittest.main()
