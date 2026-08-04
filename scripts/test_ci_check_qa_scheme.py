#!/usr/bin/env python3
"""Regression tests for the isolated QA scheme contract guard."""

from __future__ import annotations

import unittest
from pathlib import Path

from scripts.ci_check_qa_scheme import (
    QAContractError,
    validate_contract_texts,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_FILE = REPO_ROOT / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
SCHEME_FILE = (
    REPO_ROOT
    / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/xcshareddata/xcschemes/CLIPulse QA.xcscheme"
)


def replace_after(
    text: str,
    marker: str,
    old: str,
    new: str,
) -> str:
    prefix, separator, suffix = text.partition(marker)
    if not separator:
        raise AssertionError(f"missing fixture marker: {marker!r}")
    changed_suffix = suffix.replace(old, new, 1)
    if changed_suffix == suffix:
        raise AssertionError(
            f"missing fixture value {old!r} after {marker!r}"
        )
    return prefix + separator + changed_suffix


class QASchemeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project_text = PROJECT_FILE.read_text(encoding="utf-8")
        cls.scheme_text = SCHEME_FILE.read_text(encoding="utf-8")

    def assert_rejected(
        self,
        *,
        project_text: str | None = None,
        scheme_text: str | None = None,
    ) -> None:
        with self.assertRaises(QAContractError):
            validate_contract_texts(
                project_text or self.project_text,
                scheme_text or self.scheme_text,
            )

    def test_current_contract_is_accepted(self) -> None:
        validate_contract_texts(self.project_text, self.scheme_text)

    def test_launch_action_must_use_debug_qa(self) -> None:
        mutated = self.scheme_text.replace(
            '<LaunchAction\n      buildConfiguration = "Debug QA"',
            '<LaunchAction\n      buildConfiguration = "Debug"',
            1,
        )
        self.assertNotEqual(mutated, self.scheme_text)
        self.assert_rejected(scheme_text=mutated)

    def test_qa_home_must_be_fixed_enabled_and_isolated(self) -> None:
        mutated = replace_after(
            self.scheme_text,
            'key = "CFFIXED_USER_HOME"',
            'value = "/private/tmp/clipulse-qa-home"',
            'value = "/Users/shared/clipulse-qa-home"',
        )
        self.assert_rejected(scheme_text=mutated)

    def test_reset_must_default_to_disabled(self) -> None:
        mutated = replace_after(
            self.scheme_text,
            'key = "CLIPULSE_QA_RESET_ON_LAUNCH"',
            'value = "0"',
            'value = "1"',
        )
        self.assert_rejected(scheme_text=mutated)

    def test_preaction_must_reject_symlink_roots(self) -> None:
        mutated = self.scheme_text.replace(
            "if [ -L &quot;$qa_root&quot; ]; then",
            "if false; then",
            1,
        )
        self.assertNotEqual(mutated, self.scheme_text)
        self.assert_rejected(scheme_text=mutated)

    def test_app_qa_bundle_must_not_fall_back_to_production(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G10008 /* Debug QA */",
            "PRODUCT_BUNDLE_IDENTIFIER = app.clipulse.qa.local;",
            'PRODUCT_BUNDLE_IDENTIFIER = "yyh.CLI-Pulse";',
        )
        self.assert_rejected(project_text=mutated)

    def test_app_qa_configuration_must_not_gain_entitlements(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G10008 /* Debug QA */",
            'CODE_SIGN_ENTITLEMENTS = "";',
            'CODE_SIGN_ENTITLEMENTS = "CLI Pulse Bar/CLI_Pulse_Bar.entitlements";',
        )
        self.assert_rejected(project_text=mutated)

    def test_helper_qa_bundle_must_stay_isolated(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G60004 /* Debug QA */",
            "PRODUCT_BUNDLE_IDENTIFIER = app.clipulse.qa.local.helper;",
            'PRODUCT_BUNDLE_IDENTIFIER = "yyh.CLI-Pulse.helper";',
        )
        self.assert_rejected(project_text=mutated)


if __name__ == "__main__":
    unittest.main()
