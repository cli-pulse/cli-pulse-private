"""The helper's `claude /usage` fallback must not open a Claude Code Remote
Control session.

A probe that did would leave an empty session in the user's claude.ai and
Claude app for every refresh that reaches this fallback (CodexBar #3651). The
app's own probe is pinned the same way in
`CLIPulseCoreTests/ClaudeProbeRemoteControlTests.swift`; this file covers the
copy of the probe that ships in the helper .pkg.
"""
from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import system_collector
from system_collector import (
    _CLAUDE_USAGE_PROBE_ARGS,
    _fetch_claude_cli,
    _parse_claude_usage_output,
)

FAKE_BINARY = "/opt/fake/bin/claude"

# The shape `claude /usage` prints in print mode (stdout not a terminal),
# Claude Code 2.1.266. The numbers and reset times are made up.
PLAN_LIMITS_OUTPUT = """You are currently using your subscription to power your Claude Code usage

Current session: 12% used · resets Oct 1 at 3am (UTC)
Current week (all models): 40% used · resets Oct 6 at 9pm (UTC)
"""

# What `claude --bare /usage` printed instead, Claude Code 2.1.266. Bare mode
# never reads the claude.ai login, so there is no plan to report.
BARE_OUTPUT = """Total cost:            $0.0000
Total duration (API):  0s
Total duration (wall): 0s
Total code changes:    0 lines added, 0 lines removed
Usage:                 0 input, 0 output, 0 cache read, 0 cache write
"""

APP_PROBE_SOURCE = (
    Path(__file__).resolve().parent.parent
    / "CLI Pulse Bar" / "CLIPulseCore" / "Sources" / "CLIPulseCore"
    / "Collectors" / "Claude" / "ClaudeCLIPTYStrategy.swift"
)


class ClaudeUsageProbeArgumentsTests(unittest.TestCase):

    def _settings_passed(self) -> dict:
        """The value that follows `--settings`, parsed the way Claude Code parses it."""
        args = list(_CLAUDE_USAGE_PROBE_ARGS)
        self.assertIn("--settings", args, "the probe must pass its own --settings")
        index = args.index("--settings")
        self.assertLess(index + 1, len(args), "--settings needs a value")
        value = json.loads(args[index + 1])
        self.assertIsInstance(
            value, dict,
            "--settings must be a JSON object, or Claude Code rejects the launch",
        )
        return value

    def test_probe_turns_remote_control_off_for_itself(self):
        # `False`, not absent and not `True`: an absent key falls back to the
        # user's own setting, or the account default, which is what this guards against.
        self.assertIs(self._settings_passed().get("remoteControlAtStartup"), False)

    def test_probe_settings_change_nothing_else(self):
        # A flag-scope setting overrides the user's for this process. Anything
        # beyond the one key would quietly change how their Claude Code behaves
        # inside the probe.
        self.assertEqual(list(self._settings_passed()), ["remoteControlAtStartup"])

    def test_same_opt_out_as_the_app_probe(self):
        # The helper .pkg and the app ask Claude Code the same question and
        # should turn off the same thing. If the app's setting changes (a
        # renamed key, say), this fails until the helper follows.
        text = APP_PROBE_SOURCE.read_text(encoding="utf-8")
        match = re.search(r'"--settings",\s*#"(.*?)"#', text)
        self.assertIsNotNone(
            match, f"no --settings value found in {APP_PROBE_SOURCE.name}",
        )
        self.assertEqual(json.loads(match.group(1)), self._settings_passed())

    def test_usage_is_the_command_after_the_flags(self):
        # `/usage` is a positional argument. Anywhere but last, it could be
        # read as the value of the flag before it.
        self.assertEqual(_CLAUDE_USAGE_PROBE_ARGS[-1], "/usage")
        self.assertEqual(_CLAUDE_USAGE_PROBE_ARGS.count("/usage"), 1)

    def test_probe_does_not_pass_bare(self):
        # The app's probe passes `--bare`; this one must not. Bare mode never
        # reads the claude.ai login, so `/usage` prints a cost summary instead
        # of the plan limits (next test), and the fallback would never produce
        # a bar.
        self.assertNotIn("--bare", _CLAUDE_USAGE_PROBE_ARGS)

    def test_bare_output_has_no_plan_limits(self):
        self.assertIsNone(_parse_claude_usage_output(BARE_OUTPUT))


class FetchClaudeCliLaunchTests(unittest.TestCase):
    """The arguments above are only worth testing if they are what gets launched."""

    def _run_fallback(self, stdout: str):
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=stdout, stderr="",
        )
        with mock.patch("shutil.which", return_value=FAKE_BINARY), \
                mock.patch.object(
                    system_collector.subprocess, "run", return_value=completed,
                ) as run:
            result = _fetch_claude_cli("Pro")
        run.assert_called_once()
        return run, result

    def test_fallback_launches_the_probe_arguments(self):
        run, _ = self._run_fallback(PLAN_LIMITS_OUTPUT)
        self.assertEqual(run.call_args.args[0], [FAKE_BINARY, *_CLAUDE_USAGE_PROBE_ARGS])
        # Unchanged guard: a prompt from a future build must not wait on stdin.
        self.assertIs(run.call_args.kwargs.get("stdin"), subprocess.DEVNULL)

    def test_fallback_still_reads_the_plan_limits(self):
        _, result = self._run_fallback(PLAN_LIMITS_OUTPUT)
        self.assertIsNotNone(result)
        self.assertEqual([t["name"] for t in result["tiers"]], ["5h Window", "Weekly"])
        self.assertEqual(result["tiers"][0]["remaining"], 88)
        self.assertEqual(result["tiers"][1]["remaining"], 60)
        self.assertEqual(result["plan_type"], "Pro")


if __name__ == "__main__":
    unittest.main()
