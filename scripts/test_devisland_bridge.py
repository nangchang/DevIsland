#!/usr/bin/env python3
"""Regression tests for devisland_bridge.py event-allow-list normalization."""

import unittest

from devisland_bridge import _normalize_event, _PASSIVE_EVENTS_NORMALIZED, final_output


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

    def test_pretooluse_denied_codex(self):
        out = final_output(event="pretooluse", decision="denied", provider_output=None, cli_source="codex")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_userpromptsubmit_denied_claude(self):
        out = final_output(event="userpromptsubmit", decision="denied", provider_output=None, cli_source="claude")
        self.assertEqual(out["decision"], "block")

    def test_elicitation_denied_claude(self):
        out = final_output(event="elicitation", decision="denied", provider_output=None, cli_source="claude")
        self.assertEqual(out["hookSpecificOutput"]["action"], "decline")


if __name__ == "__main__":
    unittest.main()
