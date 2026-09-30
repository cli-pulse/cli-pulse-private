"""Suite-wide fixtures for the helper tests."""
from __future__ import annotations

import sys

import pytest


@pytest.fixture(autouse=True)
def _app_group_copy_is_read_from_the_file(monkeypatch):
    """Tests write the app's app-group plist straight to disk, under a
    throwaway HOME. `local_scan_consent.read_mirror` asks cfprefsd first
    (`app_group_prefs`), and cfprefsd keeps serving its first read of a path
    when the file is then rewritten behind its back, so on a Mac those tests
    would read a stale copy. The tests of the cfprefsd path
    (`test_privacy_switches.py`) turn it back on and write through
    CFPreferences, as the app does."""
    import app_group_prefs

    monkeypatch.setattr(app_group_prefs, "ENABLED", False)
    yield
    # The Claude keychain gates are installed process-wide by the daemon and
    # the `heartbeat` / `sync` / `run-demo` subcommands
    # (`cli_pulse_helper._install_claude_keychain_gate`). A test that runs one
    # must not leave its gate, over a HOME that no longer exists, to the next.
    for module, attribute in (
        ("system_collector", "_claude_keychain_gate"),
        ("claude_oauth", "_keychain_gate"),
    ):
        loaded = sys.modules.get(module)
        if loaded is not None:
            setattr(loaded, attribute, None)
