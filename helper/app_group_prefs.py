"""Read the Mac app's app-group defaults through cfprefsd, not from disk.

The app writes what it tells the helpers (the local-scan answer, the sign-in
state, Settings › Privacy's Claude keychain switches) with
`UserDefaults(suiteName: "group.yyh.CLI-Pulse")`. That write goes to cfprefsd,
which holds the value in memory and writes the plist file later. Measured on
macOS 27 (2026-10-01): after a write that nothing synchronizes, which is how
`UserDefaults.set` writes, the plist file on disk still held the previous value
for 8.6 to 9.9 seconds, and a read straight after each of 30 writes found the
file stale 15 times. A reader that parses the file therefore acts on the
previous answer for up to ten seconds: a "Not now" or a switch turned on in
that window is not yet seen.

`CFPreferencesCopyAppValue` asks cfprefsd, which answers with what the app
wrote. Given the plist's absolute path as the application ID it reads that
exact file's domain, whichever process wrote it; the same 30 writes read back
fresh every time, in one long-lived reader too. So this module is the first
thing `local_scan_consent.read_mirror` tries, and the plist file is the
fallback (see there).

It is ctypes onto CoreFoundation, which every Mac has, so the frozen helper
needs no PyObjC. It returns None whenever it cannot answer: not macOS,
CoreFoundation not loadable, a call that fails, or no value for any key asked.
None means "ask the file", never "no copy".

`ENABLED` is switched off for the test suite (`conftest.py`): tests write plist
files straight to disk, which cfprefsd would not see after its first read of
that path.
"""
from __future__ import annotations

import ctypes
import logging
import sys
from pathlib import Path
from typing import Iterable

logger = logging.getLogger("cli_pulse.app_group_prefs")

ENABLED = sys.platform == "darwin"

_CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
_UTF8 = 0x08000100  # kCFStringEncodingUTF8
_DOUBLE = 13  # kCFNumberDoubleType
_SINT64 = 4  # kCFNumberSInt64Type


class Unsupported:
    """A value of a type this reader does not convert (data, array,
    dictionary). Present, so not "missing"; never equal to an answer."""

    def __init__(self, type_id: int) -> None:
        self.type_id = type_id

    def __repr__(self) -> str:
        return f"Unsupported(CFTypeID {self.type_id})"


_cf = None
_cf_failed = False


def _load():
    global _cf, _cf_failed
    if _cf is not None or _cf_failed:
        return _cf
    try:
        cf = ctypes.CDLL(_CF_PATH)
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFPreferencesCopyAppValue.restype = ctypes.c_void_p
        cf.CFPreferencesCopyAppValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFGetTypeID.restype = ctypes.c_ulong
        cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
        for name in ("CFBooleanGetTypeID", "CFStringGetTypeID", "CFNumberGetTypeID"):
            getattr(cf, name).restype = ctypes.c_ulong
            getattr(cf, name).argtypes = []
        cf.CFBooleanGetValue.restype = ctypes.c_bool
        cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
        cf.CFStringGetLength.restype = ctypes.c_long
        cf.CFStringGetLength.argtypes = [ctypes.c_void_p]
        cf.CFStringGetMaximumSizeForEncoding.restype = ctypes.c_long
        cf.CFStringGetMaximumSizeForEncoding.argtypes = [ctypes.c_long, ctypes.c_uint32]
        cf.CFStringGetCString.restype = ctypes.c_bool
        cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        cf.CFNumberIsFloatType.restype = ctypes.c_bool
        cf.CFNumberIsFloatType.argtypes = [ctypes.c_void_p]
        cf.CFNumberGetValue.restype = ctypes.c_bool
        cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        _cf = cf
    except Exception as exc:  # noqa: BLE001 — no CoreFoundation: the file is the answer
        logger.debug("CoreFoundation not loadable (%s): reading the plist file instead", exc)
        _cf_failed = True
    return _cf


def _cfstr(cf, text: str):
    ref = cf.CFStringCreateWithCString(None, text.encode("utf-8"), _UTF8)
    if not ref:
        raise ValueError("CFStringCreateWithCString failed")
    return ref


def _to_python(cf, ref):
    type_id = cf.CFGetTypeID(ref)
    if type_id == cf.CFBooleanGetTypeID():
        return bool(cf.CFBooleanGetValue(ref))
    if type_id == cf.CFStringGetTypeID():
        size = cf.CFStringGetMaximumSizeForEncoding(cf.CFStringGetLength(ref), _UTF8) + 1
        buf = ctypes.create_string_buffer(size)
        if not cf.CFStringGetCString(ref, buf, size, _UTF8):
            return Unsupported(type_id)
        return buf.value.decode("utf-8")
    if type_id == cf.CFNumberGetTypeID():
        if cf.CFNumberIsFloatType(ref):
            out = ctypes.c_double()
            cf.CFNumberGetValue(ref, _DOUBLE, ctypes.byref(out))
            return out.value
        out = ctypes.c_int64()
        cf.CFNumberGetValue(ref, _SINT64, ctypes.byref(out))
        return out.value
    return Unsupported(type_id)


def copy_values(plist_path: Path, keys: Iterable[str]) -> dict | None:
    """What cfprefsd holds for `keys` in the defaults domain stored at
    `plist_path`. Keys with no value are left out. None when this cannot ask
    cfprefsd, or when no key has a value (the caller then reads the file,
    which alone can tell a missing file from an unreadable one). Never raises.
    """
    if not ENABLED:
        return None
    cf = _load()
    if cf is None:
        return None
    refs = []
    try:
        app_id = _cfstr(cf, str(plist_path))
        refs.append(app_id)
        values: dict = {}
        for key in keys:
            key_ref = _cfstr(cf, key)
            refs.append(key_ref)
            value_ref = cf.CFPreferencesCopyAppValue(key_ref, app_id)
            if not value_ref:
                continue
            try:
                values[key] = _to_python(cf, value_ref)
            finally:
                cf.CFRelease(value_ref)
        return values or None
    except Exception as exc:  # noqa: BLE001 — cannot ask: the file is the answer
        logger.debug("CFPreferences read of %s failed: %s", plist_path, exc)
        return None
    finally:
        for ref in refs:
            cf.CFRelease(ref)
