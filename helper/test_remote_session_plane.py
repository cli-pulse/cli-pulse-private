"""The retirement flag agrees across all three packages, and gates the producer.

The Swift copies already have a drift gate between themselves
(`RemoteSessionPlaneRetirementTests.test_theHelperCopyOfTheFlagAgrees`). This
adds the third: a copied constant without a drift gate is how a "retired"
feature comes back on one side only, and the Python helper is the copy most
likely to be forgotten because it ships as a separate .pkg.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from remote_session_plane import IS_ENABLED, should_run_terminal_broadcast

REPO = Path(__file__).resolve().parents[1]
SWIFT_COPIES = [
    REPO / "HelperSwift/Sources/HelperKit/RemoteSessionPlane.swift",
    REPO / "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteSessionPlane.swift",
]


@pytest.mark.parametrize("path", SWIFT_COPIES, ids=lambda p: p.parent.name)
def test_the_python_copy_agrees_with_each_swift_copy(path: Path) -> None:
    assert path.exists(), f"the Swift copy moved: {path}"
    line = next(
        (ln for ln in path.read_text(encoding="utf-8").splitlines()
         if "static let isEnabled" in ln),
        None,
    )
    assert line is not None, f"the isEnabled declaration moved in {path.name}"
    m = re.search(r"static let isEnabled\s*=\s*(true|false)", line)
    assert m is not None, f"could not parse: {line!r}"
    swift_value = m.group(1) == "true"
    assert swift_value == IS_ENABLED, (
        f"{path.name} says isEnabled={swift_value} but the Python copy says "
        f"{IS_ENABLED} — the retirement came back on one side only"
    )


def test_the_ops_flag_cannot_outvote_the_retirement() -> None:
    # The conjunction, all four ways.
    for cfg in (True, False):
        assert should_run_terminal_broadcast(cfg) is (IS_ENABLED and cfg)
    # Concretely, while retired: nothing turns the producer on.
    assert should_run_terminal_broadcast(True) is False, (
        "remote_realtime_broadcast_enabled defaults ON since helper 1.24.0, so "
        "without this the producer runs for a retired plane"
    )


def test_the_producer_construction_actually_calls_the_gate() -> None:
    # A predicate nothing calls is a predicate that gates nothing — this file
    # family has shipped that mistake twice.
    src = (REPO / "helper/cli_pulse_helper.py").read_text(encoding="utf-8")
    assert "from remote_session_plane import should_run_terminal_broadcast" in src
    assert "if should_run_terminal_broadcast(" in src, (
        "the producer construction no longer routes through the retirement gate"
    )
