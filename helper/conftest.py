"""Suite-wide fixtures for the helper tests."""
from __future__ import annotations

import ctypes
import plistlib
import sys
from pathlib import Path

import pytest

# CFPreferences exists only on a Mac. Helper CI runs the whole suite on Linux,
# where these tests skip, and the tests of the app's app-group copy again on
# macOS, where a skip fails the job (`.github/workflows/helper-ci.yml`).
darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="CFPreferences is macOS-only")


@pytest.fixture(autouse=True)
def _app_group_copy_is_read_from_the_file(monkeypatch):
    """Tests write the app's app-group plist straight to disk, under a
    throwaway HOME. `local_scan_consent.read_mirror` asks cfprefsd first
    (`app_group_prefs`), and cfprefsd keeps serving its first read of a path
    when the file is then rewritten behind its back, so on a Mac those tests
    would read a stale copy. The tests of the cfprefsd path turn it back on and
    write through CFPreferences, as the app does (`app_group_copy`,
    `cfprefs_writer`)."""
    import app_group_prefs

    monkeypatch.setattr(app_group_prefs, "ENABLED", False)
    yield
    # The Privacy switch gates (Claude keychain, browser cookies) are
    # installed process-wide by the daemon and the `heartbeat` / `sync` /
    # `run-demo` subcommands (`cli_pulse_helper._install_claude_keychain_gate`).
    # A test that runs one must not leave its gate, over a HOME that no longer
    # exists, to the next.
    for module, attribute in (
        ("system_collector", "_claude_keychain_gate"),
        ("system_collector", "_browser_cookie_gate"),
        ("claude_oauth", "_keychain_gate"),
    ):
        loaded = sys.modules.get(module)
        if loaded is not None:
            setattr(loaded, attribute, None)


class CFPrefsWriter:
    """Writes a defaults domain, named by its plist's absolute path, through
    CFPreferences, the way `UserDefaults.set` writes in the app: to cfprefsd,
    which writes the file later. Remembers every key it set, so `clear` can
    take them all back."""

    def __init__(self, path: Path) -> None:
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFPreferencesSetAppValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        cf.CFPreferencesAppSynchronize.argtypes = [ctypes.c_void_p]
        cf.CFPreferencesAppSynchronize.restype = ctypes.c_bool
        cf.CFNumberCreate.restype = ctypes.c_void_p
        cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        cf.CFDataCreate.restype = ctypes.c_void_p
        cf.CFDataCreate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long]
        self.cf = cf
        self.app = self._str(str(path))
        self.true = ctypes.c_void_p.in_dll(cf, "kCFBooleanTrue")
        self.false = ctypes.c_void_p.in_dll(cf, "kCFBooleanFalse")
        self._keys: set[str] = set()

    def _str(self, text: str):
        return self.cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)

    def set(self, key: str, value) -> None:
        """`value` None removes the key."""
        if isinstance(value, bool):
            ref = self.true if value else self.false
        elif isinstance(value, str):
            ref = self._str(value)
        elif isinstance(value, int):
            box = ctypes.c_int64(value)
            ref = self.cf.CFNumberCreate(None, 4, ctypes.byref(box))
        elif isinstance(value, bytes):
            ref = self.cf.CFDataCreate(None, value, len(value))
        elif value is None:
            ref = None
        else:
            raise TypeError(value)
        self.cf.CFPreferencesSetAppValue(self._str(key), ref, self.app)
        if value is None:
            self._keys.discard(key)
        else:
            self._keys.add(key)

    def replace(self, values: dict | None) -> None:
        """Leave the domain holding exactly `values` (nothing, for None), and
        synchronize, so that a read that falls back to the file does not find
        what an earlier write left there."""
        values = values or {}
        for key in sorted(self._keys - set(values)):
            self.set(key, None)
        for key, value in values.items():
            self.set(key, value)
        self.flush()

    def flush(self) -> None:
        self.cf.CFPreferencesAppSynchronize(self.app)

    def clear(self) -> None:
        for key in sorted(self._keys):
            self.set(key, None)
        self.flush()


@pytest.fixture
def cfprefs_writer():
    """`make(path)` -> a `CFPrefsWriter`; every key it set is removed again
    after the test."""
    made: list[CFPrefsWriter] = []

    def make(path: Path) -> CFPrefsWriter:
        writer = CFPrefsWriter(path)
        made.append(writer)
        return writer

    yield make
    for writer in made:
        writer.clear()


class _FileCopy:
    """The app's copy written as a plist file, as the tests always did."""

    source = "file"

    def write(self, values: dict | None) -> None:
        import local_scan_consent

        path = local_scan_consent.mirror_plist_path()
        if values is None:
            path.unlink(missing_ok=True)
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as fh:
            plistlib.dump(values, fh, fmt=plistlib.FMT_BINARY)


class _CFPrefsCopy:
    """The app's copy written through cfprefsd, as the app writes it, and read
    the way production reads it (`app_group_prefs.ENABLED`)."""

    source = "cfprefsd"

    def __init__(self, make_writer) -> None:
        self._make_writer = make_writer
        self._writer: CFPrefsWriter | None = None

    def write(self, values: dict | None) -> None:
        import local_scan_consent

        if self._writer is None:
            path = local_scan_consent.mirror_plist_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            self._writer = self._make_writer(path)
        self._writer.replace(values)


@pytest.fixture(params=["file", pytest.param("cfprefsd", marks=darwin_only)])
def app_group_copy(request, monkeypatch, cfprefs_writer):
    """Writes the app's app-group copy (`.write(values)`, where HOME points
    now) both ways the Companion can read it: as a file, and through cfprefsd
    with the cfprefsd reader on, which is how it reads it on every Mac. A key
    that `local_scan_consent` reads but does not ask cfprefsd for fails the
    second."""
    if request.param == "file":
        return _FileCopy()
    import app_group_prefs

    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    return _CFPrefsCopy(cfprefs_writer)
