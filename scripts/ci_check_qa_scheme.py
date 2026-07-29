#!/usr/bin/env python3
"""Verify that the QA scheme references the target's stable product entry."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_FILE = REPO_ROOT / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
SCHEME_FILE = (
    REPO_ROOT
    / "CLI Pulse Bar/CLI Pulse Bar.xcodeproj/xcshareddata/xcschemes/CLIPulse QA.xcscheme"
)
TARGET_ID = "F10001"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


project_text = PROJECT_FILE.read_text(encoding="utf-8")
target_match = re.search(
    rf"^\s*{TARGET_ID}\s+/\*.*?\*/\s*=\s*\{{(?P<body>.*?)^\s*\}};",
    project_text,
    flags=re.MULTILINE | re.DOTALL,
)
if target_match is None:
    fail(f"target {TARGET_ID} was not found in {PROJECT_FILE}")

product_reference_match = re.search(
    r"productReference\s*=\s*(?P<id>[A-Z0-9]+)\s+/\*.*?\*/;",
    target_match.group("body"),
)
if product_reference_match is None:
    fail(f"target {TARGET_ID} has no productReference")

product_reference_id = product_reference_match.group("id")
file_reference_match = re.search(
    rf"^\s*{product_reference_id}\s+/\*.*?\*/\s*=\s*\{{"
    rf".*?\bpath\s*=\s*(?:\"(?P<quoted>[^\"]+)\"|(?P<plain>[^;]+));",
    project_text,
    flags=re.MULTILINE,
)
if file_reference_match is None:
    fail(f"product reference {product_reference_id} has no path")

expected_name = (
    file_reference_match.group("quoted") or file_reference_match.group("plain")
).strip()
scheme_root = ET.parse(SCHEME_FILE).getroot()
target_references = [
    element
    for element in scheme_root.iter("BuildableReference")
    if element.attrib.get("BlueprintIdentifier") == TARGET_ID
]
if not target_references:
    fail(f"scheme contains no BuildableReference for target {TARGET_ID}")

mismatches = [
    element.attrib.get("BuildableName")
    for element in target_references
    if element.attrib.get("BuildableName") != expected_name
]
if mismatches:
    fail(
        f"{SCHEME_FILE.name} must use BuildableName={expected_name!r} for target "
        f"{TARGET_ID}; found {mismatches!r}"
    )

print(
    f"PASS: {SCHEME_FILE.name} uses the stable target product reference "
    f"{expected_name!r}"
)
