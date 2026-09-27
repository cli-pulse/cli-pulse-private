#!/usr/bin/env python3
"""Regression tests for the isolated QA scheme contract guard."""

from __future__ import annotations

import unittest
from pathlib import Path

from scripts.ci_check_qa_scheme import (
    QAContractError,
    tracked_files_outside_project,
    validate_contract_texts,
    validate_render_condition_outside_project,
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

    def test_render_mode_must_stay_compiled_into_qa(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G10008 /* Debug QA */",
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CLIPULSE_QA_RENDER";',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited)";',
        )
        self.assert_rejected(project_text=mutated)

    def test_render_mode_must_keep_inherited_conditions(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G10008 /* Debug QA */",
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CLIPULSE_QA_RENDER";',
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = CLIPULSE_QA_RENDER;",
        )
        self.assert_rejected(project_text=mutated)

    def test_render_mode_must_not_reach_release(self) -> None:
        # G10006 is the app's Release configuration: the Mac App Store and
        # Developer ID builds.
        mutated = replace_after(
            self.project_text,
            "G10006 /* Release */ = {",
            "buildSettings = {",
            "buildSettings = {\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "
            '"$(inherited) CLIPULSE_QA_RENDER";',
        )
        self.assert_rejected(project_text=mutated)

    def test_render_mode_must_not_reach_release_through_other_swift_flags(self) -> None:
        # `-DCLIPULSE_QA_RENDER` has no word boundary before the name, so a
        # `\b` count missed it.
        mutated = replace_after(
            self.project_text,
            "G10006 /* Release */ = {",
            "buildSettings = {",
            "buildSettings = {\n\t\t\t\tOTHER_SWIFT_FLAGS = "
            '"$(inherited) -DCLIPULSE_QA_RENDER";',
        )
        self.assert_rejected(project_text=mutated)

    def test_render_mode_must_not_reach_plain_debug(self) -> None:
        mutated = replace_after(
            self.project_text,
            "G10005 /* Debug */ = {",
            "buildSettings = {",
            "buildSettings = {\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "
            '"$(inherited) CLIPULSE_QA_RENDER";',
        )
        self.assert_rejected(project_text=mutated)


class RenderConditionOutsideProjectTests(unittest.TestCase):
    """The render condition could also be switched on without touching the
    project file: an xcconfig, or an `xcodebuild` override in a release script
    or workflow. The runtime guard would still refuse to render, but the build
    would ship the renderer and start at a different `@main`."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.files = tracked_files_outside_project(REPO_ROOT)

    def test_the_tracked_scripts_and_workflows_are_accepted(self) -> None:
        # Control: the scan reads real files, and the tree is clean today.
        self.assertTrue(any(path.endswith(".sh") for path in self.files))
        self.assertTrue(any(path.startswith(".github/workflows/") for path in self.files))
        validate_render_condition_outside_project(self.files)

    def assert_leak_rejected(self, path: str, text: str) -> None:
        files = dict(self.files)
        files[path] = text
        with self.assertRaises(QAContractError) as caught:
            validate_render_condition_outside_project(files)
        self.assertIn(path, str(caught.exception))

    def test_an_xcconfig_must_not_define_it(self) -> None:
        self.assert_leak_rejected(
            "CLI Pulse Bar/Release.xcconfig",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) CLIPULSE_QA_RENDER\n",
        )

    def test_a_release_script_must_not_pass_it_to_xcodebuild(self) -> None:
        self.assert_leak_rejected(
            "scripts/build_devid_dmg.sh",
            'xcodebuild archive SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) CLIPULSE_QA_RENDER"\n',
        )

    def test_a_workflow_must_not_pass_it_through_other_swift_flags(self) -> None:
        self.assert_leak_rejected(
            ".github/workflows/release.yml",
            "run: xcodebuild OTHER_SWIFT_FLAGS=-DCLIPULSE_QA_RENDER\n",
        )


if __name__ == "__main__":
    unittest.main()
