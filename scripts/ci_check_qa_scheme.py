#!/usr/bin/env python3
"""Fail closed when the isolated macOS QA launch contract drifts."""

from __future__ import annotations

import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_FILE = REPO_ROOT / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
SCHEME_FILE = (
    REPO_ROOT
    / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/xcshareddata/xcschemes/CLIPulse QA.xcscheme"
)

APP_TARGET_ID = "F10001"
APP_CONFIG_LIST_ID = "G10003"
APP_QA_CONFIG_ID = "G10008"
HELPER_TARGET_ID = "F60001"
HELPER_CONFIG_LIST_ID = "G60003"
HELPER_QA_CONFIG_ID = "G60004"
PROJECT_CONFIG_LIST_ID = "G10001"
PROJECT_QA_CONFIG_ID = "G10007"
QA_CONFIGURATION = "Debug QA"
QA_HOME = "/private/tmp/clipulse-qa-home"
# The offscreen renderer (CLI Pulse Bar/QASnapshotRenderer.swift) and its view
# hooks compile only where this condition is defined. See
# docs/qa/macos-offscreen-renders.md.
QA_RENDER_CONDITION = "CLIPULSE_QA_RENDER"


class QAContractError(ValueError):
    """Raised when the checked-in QA isolation contract is unsafe."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise QAContractError(message)


def object_body(project_text: str, object_id: str) -> str:
    match = re.search(
        rf"^\s*{re.escape(object_id)}\s+/\*.*?\*/\s*=\s*\{{"
        rf"(?P<body>.*?)^\s*\}};",
        project_text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise QAContractError(f"project object {object_id} was not found")
    return match.group("body")


def build_settings(
    project_text: str,
    configuration_id: str,
) -> dict[str, str]:
    match = re.search(
        rf"^\s*{re.escape(configuration_id)}\s+/\*.*?\*/\s*=\s*\{{"
        rf".*?buildSettings\s*=\s*\{{(?P<settings>.*?)^\s*\}};"
        rf"\s*name\s*=\s*(?P<name>\"[^\"]+\"|[^;]+);",
        project_text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise QAContractError(
            f"build configuration {configuration_id} was not found"
        )
    name = match.group("name").strip().strip('"')
    require(
        name == QA_CONFIGURATION,
        f"{configuration_id} must be named {QA_CONFIGURATION!r}; found {name!r}",
    )

    parsed: dict[str, str] = {}
    for setting in re.finditer(
        r"^\s*(?P<key>[A-Z][A-Z0-9_]*)\s*=\s*"
        r"(?P<value>\"[^\"]*\"|[^;]*);",
        match.group("settings"),
        flags=re.MULTILINE,
    ):
        parsed[setting.group("key")] = (
            setting.group("value").strip().strip('"')
        )
    return parsed


def require_settings(
    settings: dict[str, str],
    expected: dict[str, str],
    label: str,
) -> None:
    for key, expected_value in expected.items():
        actual = settings.get(key)
        require(
            actual == expected_value,
            f"{label} must set {key}={expected_value!r}; found {actual!r}",
        )


def require_configuration_membership(
    project_text: str,
    list_id: str,
    configuration_id: str,
) -> None:
    body = object_body(project_text, list_id)
    require(
        re.search(
            rf"^\s*{re.escape(configuration_id)}\s+/\*\s*Debug QA\s*\*/,?$",
            body,
            flags=re.MULTILINE,
        )
        is not None,
        f"configuration list {list_id} must include {configuration_id} (Debug QA)",
    )


def target_product_name(project_text: str) -> str:
    target_body = object_body(project_text, APP_TARGET_ID)
    product_reference_match = re.search(
        r"productReference\s*=\s*(?P<id>[A-Z0-9]+)\s+/\*.*?\*/;",
        target_body,
    )
    require(
        product_reference_match is not None,
        f"target {APP_TARGET_ID} has no productReference",
    )
    product_reference_id = product_reference_match.group("id")
    file_reference_match = re.search(
        rf"^\s*{re.escape(product_reference_id)}\s+/\*.*?\*/\s*=\s*\{{"
        rf".*?\bpath\s*=\s*(?:\"(?P<quoted>[^\"]+)\"|(?P<plain>[^;]+));",
        project_text,
        flags=re.MULTILINE,
    )
    require(
        file_reference_match is not None,
        f"product reference {product_reference_id} has no path",
    )
    return (
        file_reference_match.group("quoted")
        or file_reference_match.group("plain")
    ).strip()


def validate_render_condition(project_text: str) -> None:
    """The render mode exists in the QA app and nowhere else.

    `CLIPULSE_QA_RENDER` must be an active compilation condition of the app's
    Debug QA configuration, and must not appear in any other object of the
    project: not in Debug, not in Release (which the Mac App Store and
    Developer ID builds use), not in another target. The QA build's entry
    point is compiled from the same condition, so a configuration that gained
    it would also start somewhere else than `CLIPulseBarApp`.
    """
    qa_body = object_body(project_text, APP_QA_CONFIG_ID)
    conditions = build_settings(project_text, APP_QA_CONFIG_ID).get(
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""
    ).split()
    require(
        QA_RENDER_CONDITION in conditions,
        f"app Debug QA configuration must define {QA_RENDER_CONDITION} in "
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
    )
    require(
        "$(inherited)" in conditions,
        "app Debug QA SWIFT_ACTIVE_COMPILATION_CONDITIONS must keep $(inherited) "
        "so DEBUG still reaches the QA build",
    )
    # Plain substring counts, not word matches: in `-DCLIPULSE_QA_RENDER`, the
    # spelling OTHER_SWIFT_FLAGS uses, there is no word boundary between the D
    # and the C, and a `\b` pattern let that reach Release unnoticed. A longer
    # name that merely starts with the condition is counted too, which fails
    # closed.
    total = project_text.count(QA_RENDER_CONDITION)
    inside = qa_body.count(QA_RENDER_CONDITION)
    require(
        total == inside,
        f"{QA_RENDER_CONDITION} may appear only in the app's Debug QA "
        f"configuration ({APP_QA_CONFIG_ID}); found {total - inside} other "
        "occurrence(s)",
    )


# The Developer ID build's compilation condition. The QA renders stand for the
# Mac App Store build (the store set becomes its screenshots; see
# docs/qa/macos-offscreen-renders.md), so the QA build must not compile the
# Developer ID-only UI in. build_signed_app.sh passes it on the xcodebuild
# command line for the Developer ID archive only; the store set also refuses
# to run in any build that has it.
DEVID_CONDITION = "DEVID_BUILD"


def validate_no_devid_in_qa(project_text: str) -> None:
    """Neither the project's nor the app's Debug QA configuration may define
    DEVID_BUILD: not as an active compilation condition, not as `-DDEVID_BUILD`
    in OTHER_SWIFT_FLAGS, not in any other setting. A substring count, for the
    same reason as the render condition's (no word boundary after `-D`)."""
    for config_id, label in ((PROJECT_QA_CONFIG_ID, "project"), (APP_QA_CONFIG_ID, "app")):
        body = object_body(project_text, config_id)
        require(
            DEVID_CONDITION not in body,
            f"{label} Debug QA configuration ({config_id}) names {DEVID_CONDITION}: the QA "
            "renders stand for the Mac App Store build, which never compiles the Developer "
            "ID-only UI in",
        )


# Where a build setting can be given outside project.pbxproj: an xcconfig
# attached to a configuration, an `xcodebuild ... SWIFT_ACTIVE_COMPILATION_CONDITIONS=`
# override in a release script, or the same override in a workflow. None of
# them may name the render condition. The QA scheme's Debug QA configuration
# is the only place it is defined, and `validate_render_condition` holds that
# for the project file itself.
OUTSIDE_PROJECT_PATTERNS = ("*.xcconfig", "*.sh", ".github/workflows/*.yml", ".github/workflows/*.yaml")


def render_condition_leaks(files: dict[str, str]) -> list[str]:
    """Paths among `files` (path -> text) that name the render condition."""
    return sorted(path for path, text in files.items() if QA_RENDER_CONDITION in text)


def tracked_files_outside_project(repo_root: Path) -> dict[str, str]:
    """The tracked files matching `OUTSIDE_PROJECT_PATTERNS`, path -> text."""
    listing = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "-z", "--", *OUTSIDE_PROJECT_PATTERNS],
        check=True,
        capture_output=True,
    ).stdout.decode("utf-8")
    files: dict[str, str] = {}
    for relative in filter(None, listing.split("\0")):
        path = repo_root / relative
        if path.is_file():
            files[relative] = path.read_text(encoding="utf-8", errors="replace")
    require(files, "found no tracked scripts or workflows to scan; the listing is broken")
    return files


def validate_render_condition_outside_project(files: dict[str, str]) -> None:
    leaks = render_condition_leaks(files)
    require(
        not leaks,
        f"{QA_RENDER_CONDITION} may be defined only by the app's Debug QA "
        f"configuration in project.pbxproj; also named in: {', '.join(leaks)}",
    )


def validate_project(project_text: str) -> str:
    expected_product_name = target_product_name(project_text)

    app_target = object_body(project_text, APP_TARGET_ID)
    require(
        f"buildConfigurationList = {APP_CONFIG_LIST_ID} " in app_target,
        f"target {APP_TARGET_ID} must use configuration list {APP_CONFIG_LIST_ID}",
    )
    helper_target = object_body(project_text, HELPER_TARGET_ID)
    require(
        f"buildConfigurationList = {HELPER_CONFIG_LIST_ID} " in helper_target,
        f"target {HELPER_TARGET_ID} must use configuration list "
        f"{HELPER_CONFIG_LIST_ID}",
    )

    require_configuration_membership(
        project_text,
        PROJECT_CONFIG_LIST_ID,
        PROJECT_QA_CONFIG_ID,
    )
    require_configuration_membership(
        project_text,
        APP_CONFIG_LIST_ID,
        APP_QA_CONFIG_ID,
    )
    require_configuration_membership(
        project_text,
        HELPER_CONFIG_LIST_ID,
        HELPER_QA_CONFIG_ID,
    )

    require_settings(
        build_settings(project_text, PROJECT_QA_CONFIG_ID),
        {
            "CLIPULSE_CHANNEL": "qa",
            "DEVELOPMENT_TEAM": "",
        },
        "project Debug QA configuration",
    )
    require_settings(
        build_settings(project_text, APP_QA_CONFIG_ID),
        {
            "CLIPULSE_CHANNEL": "qa",
            "CODE_SIGN_ENTITLEMENTS": "",
            "CODE_SIGN_IDENTITY": "-",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": "",
            "ENABLE_APP_SANDBOX": "NO",
            "PRODUCT_BUNDLE_IDENTIFIER": "app.clipulse.qa.local",
            "PRODUCT_NAME": "CLIPulse QA",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "REGISTER_APP_GROUPS": "NO",
        },
        "app Debug QA configuration",
    )
    require_settings(
        build_settings(project_text, HELPER_QA_CONFIG_ID),
        {
            "CLIPULSE_CHANNEL": "qa",
            "CODE_SIGN_ENTITLEMENTS": "",
            "CODE_SIGN_IDENTITY": "-",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": "",
            "ENABLE_APP_SANDBOX": "NO",
            "PRODUCT_BUNDLE_IDENTIFIER": "app.clipulse.qa.local.helper",
            "PROVISIONING_PROFILE_SPECIFIER": "",
            "REGISTER_APP_GROUPS": "NO",
            "SKIP_INSTALL": "YES",
        },
        "helper Debug QA configuration",
    )
    validate_render_condition(project_text)
    validate_no_devid_in_qa(project_text)
    return expected_product_name


def require_buildable_reference(
    element: ET.Element,
    expected_product_name: str,
    *,
    context: str,
) -> None:
    require(
        element.attrib.get("BlueprintIdentifier") == APP_TARGET_ID,
        f"{context} must reference target {APP_TARGET_ID}",
    )
    require(
        element.attrib.get("BuildableName") == expected_product_name,
        f"{context} must use BuildableName={expected_product_name!r}",
    )


def validate_scheme(
    scheme_text: str,
    expected_product_name: str,
) -> None:
    try:
        root = ET.fromstring(scheme_text)
    except ET.ParseError as error:
        raise QAContractError(f"QA scheme is invalid XML: {error}") from error

    target_references = [
        element
        for element in root.iter("BuildableReference")
        if element.attrib.get("BlueprintIdentifier") == APP_TARGET_ID
    ]
    require(
        bool(target_references),
        f"scheme contains no BuildableReference for target {APP_TARGET_ID}",
    )
    for reference in target_references:
        require_buildable_reference(
            reference,
            expected_product_name,
            context="QA scheme reference",
        )

    for action_name in (
        "TestAction",
        "LaunchAction",
        "ProfileAction",
        "AnalyzeAction",
        "ArchiveAction",
    ):
        action = root.find(action_name)
        require(action is not None, f"scheme is missing {action_name}")
        require(
            action.attrib.get("buildConfiguration") == QA_CONFIGURATION,
            f"{action_name} must use {QA_CONFIGURATION!r}",
        )

    build_entries = root.findall(
        "./BuildAction/BuildActionEntries/BuildActionEntry"
    )
    app_build_entries = [
        entry
        for entry in build_entries
        if (
            entry.find("BuildableReference") is not None
            and entry.find("BuildableReference").attrib.get(
                "BlueprintIdentifier"
            )
            == APP_TARGET_ID
        )
    ]
    require(
        len(app_build_entries) == 1,
        "BuildAction must contain exactly one QA app entry",
    )
    build_entry = app_build_entries[0]
    require(
        build_entry.attrib.get("buildForTesting") == "YES"
        and build_entry.attrib.get("buildForRunning") == "YES"
        and build_entry.attrib.get("buildForProfiling") == "NO"
        and build_entry.attrib.get("buildForArchiving") == "NO",
        "QA BuildAction must build only for testing, running, and analyzing",
    )

    launch_action = root.find("LaunchAction")
    require(launch_action is not None, "scheme is missing LaunchAction")
    runnable_reference = launch_action.find(
        "./BuildableProductRunnable/BuildableReference"
    )
    require(
        runnable_reference is not None,
        "LaunchAction has no BuildableProductRunnable",
    )
    require_buildable_reference(
        runnable_reference,
        expected_product_name,
        context="LaunchAction runnable",
    )

    environment: dict[str, ET.Element] = {}
    for variable in launch_action.findall(
        "./EnvironmentVariables/EnvironmentVariable"
    ):
        key = variable.attrib.get("key", "")
        require(key not in environment, f"duplicate QA environment key {key!r}")
        environment[key] = variable
    expected_environment = {
        "CFFIXED_USER_HOME": QA_HOME,
        "CLIPULSE_QA_RESET_ON_LAUNCH": "0",
    }
    require(
        set(environment) == set(expected_environment),
        "LaunchAction must expose only the two reviewed QA environment keys",
    )
    for key, expected_value in expected_environment.items():
        variable = environment[key]
        require(
            variable.attrib.get("isEnabled") == "YES",
            f"{key} must be enabled",
        )
        require(
            variable.attrib.get("value") == expected_value,
            f"{key} must equal {expected_value!r}",
        )

    action_contents = launch_action.findall(
        "./PreActions/ExecutionAction/ActionContent"
    )
    require(
        len(action_contents) == 1,
        "LaunchAction must contain exactly one reviewed QA pre-action",
    )
    action_content = action_contents[0]
    require(
        action_content.attrib.get("title") == "Prepare isolated QA home",
        "QA pre-action title drifted",
    )
    script = action_content.attrib.get("scriptText", "")
    required_script_fragments = (
        "set -eu",
        f'qa_root="{QA_HOME}"',
        'if [ -L "$qa_root" ]; then',
        'if [ -e "$qa_root" ] && [ ! -d "$qa_root" ]; then',
        '/bin/mkdir -m 700 "$qa_root"',
        "qa_owner=$(/usr/bin/stat -f '%u' \"$qa_root\")",
        "current_uid=$(/usr/bin/id -u)",
        'if [ "$qa_owner" != "$current_uid" ]; then',
        '/bin/chmod 700 "$qa_root"',
    )
    for fragment in required_script_fragments:
        require(
            fragment in script,
            f"QA pre-action is missing fail-closed fragment {fragment!r}",
        )
    preaction_reference = action_content.find(
        "./EnvironmentBuildable/BuildableReference"
    )
    require(
        preaction_reference is not None,
        "QA pre-action has no EnvironmentBuildable",
    )
    require_buildable_reference(
        preaction_reference,
        expected_product_name,
        context="QA pre-action environment",
    )


def validate_contract_texts(
    project_text: str,
    scheme_text: str,
) -> None:
    expected_product_name = validate_project(project_text)
    validate_scheme(scheme_text, expected_product_name)


def main() -> int:
    try:
        validate_contract_texts(
            PROJECT_FILE.read_text(encoding="utf-8"),
            SCHEME_FILE.read_text(encoding="utf-8"),
        )
        validate_render_condition_outside_project(
            tracked_files_outside_project(REPO_ROOT)
        )
    except (OSError, QAContractError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: CLIPulse QA scheme and app/helper Debug QA isolation "
        "contract are intact"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
