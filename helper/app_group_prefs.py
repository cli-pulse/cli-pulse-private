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
that window is not yet seen. (`synchronize()` in the writer does not change
that: measured 2026-10-03, the file still caught up only on cfprefsd's own
schedule, about every 10 s.)

`CFPreferencesCopyAppValue` asks cfprefsd, which answers with what the app
wrote. So this module is the first thing `local_scan_consent.read_mirror`
tries, and the plist file is the fallback (see there).

WHO CFPREFSD ANSWERS
--------------------
Measured 2026-10-03 on macOS 27.0.1, with probe app groups (never the app's),
a writer that writes as the app does, and the reader both in a shell and under
a temporary LaunchAgent with a throwaway HOME.

The app's suite lives in its app-group container, and cfprefsd serves a
container's domain only to a process that macOS lets read that container. It
checks the asking process itself, on its reads:

  * a signature containermanagerd accepts for the group is let in: an App
    Store signature, a provisioning profile that names the group, or a group
    id that starts with the signer's team id;
  * anything else needs a `kTCCServiceSystemPolicyAppData` approval for that
    container. The Companion is in this case: a bare Developer ID executable,
    which cannot carry a profile, entitled to a `group.` id. The system log
    shows the same TCC service checked for the same files when a process
    opens the container itself, as the Companion does for its auth token and
    socket: one approval covers both.

Without access, cfprefsd refuses the read (its log: "rejecting read …",
"would require prompt"), CoreFoundation reads the file itself instead, and
under launchd that open is refused too: every read returns nothing and the
file read fails with EPERM. With access, this read is current. Under launchd,
for a signature that is let in (a team-prefixed probe group), each of 14
writes was seen by the reader's next poll or the one after, 6 ms to 1.2 s after
the write returned (the job polled about every 0.3 s), this module's own read
included. cfprefsd rewrote the plist file only about every 10 s, so the file
trailed by up to 10 s and never showed some writes at all. Access through a
TCC approval was not measured, because only the user can grant one;
`local_scan_consent` logs which source answered, so a real install shows it.

The call made is not what decides. Asking by the suite name instead of the
path, `CFPreferencesCopyValue` for the current user and any host, and
`NSUserDefaults(suiteName:)` all behaved exactly like this read, in a shell and
under launchd, with and without access. `defaults read` was not tried as a way
round: it is an unentitled process, so it meets the same check, and an
unentitled launchd process opening the group container is what hung in the
kernel in v1.30.2 (`scripts/pkg-scripts/cli_pulse_helper.entitlements`).

So on a user's Mac this read and the file fallback should stand or fall
together: both are the Companion reading its own container, under the same
approval.

NAMING THE DOMAIN BY PATH
-------------------------
The domain is named by its plist's absolute path, and what that path names
depends on the process:

  * without the app-group entitlement (the tests, `swift test`), the domain
    of that exact file, whichever process wrote it;
  * with it, a file named `<group>.plist` names that group's real container
    domain, whatever directory the path points into.

So an entitled helper run with HOME pointed elsewhere, as a test rig runs it,
would read the user's real answer through cfprefsd while everything else it
does, the file fallback included, uses HOME's copy. That is how the 1.55
launchd rig came to report this read as "never answering, the file ~9 s late":
its binary had no approval, so cfprefsd gave nothing, and its HOME's plist was
outside any protected container, so the fallback could read it. `copy_values`
does not ask cfprefsd for such a path (`_real_container_plist`): the file
answers, as it does for the rest of that HOME. With the user's own HOME, as
under the helper's LaunchAgent, the path is the real one and nothing changes.
"The user's own" is decided by the home folder itself, not by how HOME spells
it (`_is_under_home`), and a check that cannot decide asks cfprefsd as before.

It is ctypes onto CoreFoundation and Security, which every Mac has, so the
frozen helper needs no PyObjC. It returns None whenever it cannot answer: not
macOS, CoreFoundation not loadable, a call that fails, no value for any key
asked, or a path that names another container. None means "ask the file",
never "no copy".

`ENABLED` is switched off for the test suite (`conftest.py`): tests write plist
files straight to disk, which cfprefsd would not see after its first read of
that path.
"""
from __future__ import annotations

import ctypes
import logging
import os
import pwd
import sys
from pathlib import Path
from typing import Iterable

logger = logging.getLogger("cli_pulse.app_group_prefs")

ENABLED = sys.platform == "darwin"

_CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
_SECURITY_PATH = "/System/Library/Frameworks/Security.framework/Security"
_APP_GROUPS_ENTITLEMENT = "com.apple.security.application-groups"
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


# ── which domain a path names ─────────────────────────────────

_entitled_groups: frozenset[str] | None = None
_real_home_cache: Path | None = None
# Paths `copy_values` has logged that it does not ask cfprefsd for.
_not_asked: set[str] = set()


def entitled_app_groups() -> frozenset[str]:
    """The app groups this process's code signature claims
    (`com.apple.security.application-groups`). The frozen Companion claims
    `group.yyh.CLI-Pulse`; a plain `python3` claims none. Empty when there is
    no such entitlement, or when this cannot tell (not macOS, a call that
    fails), which leaves `copy_values` asking cfprefsd as it always has.
    Never raises."""
    global _entitled_groups
    if _entitled_groups is not None:
        return _entitled_groups
    try:
        groups = _read_entitled_app_groups()
    except Exception as exc:  # noqa: BLE001 — cannot tell; tried again next time
        logger.debug("cannot read this process's app-group entitlement: %s", exc)
        return frozenset()
    _entitled_groups = groups
    return groups


def _read_entitled_app_groups() -> frozenset[str]:
    cf = _load()
    if cf is None:
        return frozenset()
    sec = ctypes.CDLL(_SECURITY_PATH)
    sec.SecTaskCreateFromSelf.restype = ctypes.c_void_p
    sec.SecTaskCreateFromSelf.argtypes = [ctypes.c_void_p]
    sec.SecTaskCopyValueForEntitlement.restype = ctypes.c_void_p
    sec.SecTaskCopyValueForEntitlement.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    cf.CFArrayGetTypeID.restype = ctypes.c_ulong
    cf.CFArrayGetTypeID.argtypes = []
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
    cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
    cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
    refs = []
    try:
        task = sec.SecTaskCreateFromSelf(None)
        if not task:
            raise OSError("SecTaskCreateFromSelf returned NULL")
        refs.append(task)
        name = _cfstr(cf, _APP_GROUPS_ENTITLEMENT)
        refs.append(name)
        value = sec.SecTaskCopyValueForEntitlement(task, name, None)
        if not value:
            return frozenset()  # the signature claims no app group
        refs.append(value)
        if cf.CFGetTypeID(value) != cf.CFArrayGetTypeID():
            return frozenset()
        groups = set()
        for index in range(cf.CFArrayGetCount(value)):
            item = cf.CFArrayGetValueAtIndex(value, index)  # borrowed: not released
            text = _to_python(cf, item) if item else None
            if isinstance(text, str):
                groups.add(text)
        return frozenset(groups)
    finally:
        for ref in refs:
            cf.CFRelease(ref)


def _real_home() -> Path:
    """This user's home as the user database has it, which is where cfprefsd
    and containermanagerd put the user's group containers. (`Path.home()`
    follows HOME, which a test rig points elsewhere.)"""
    global _real_home_cache
    if _real_home_cache is None:
        _real_home_cache = Path(pwd.getpwuid(os.getuid()).pw_dir)
    return _real_home_cache


def _real_container_plist(plist_path: Path) -> Path | None:
    """The user's real app-group plist that cfprefsd would answer for when
    asked by `plist_path`, if that is another file; None when cfprefsd answers
    for `plist_path` itself.

    In a process entitled to group G, CoreFoundation reads any path whose file
    is named `G.plist` as G's container domain (see the module doc). Raises
    when it cannot tell (`copy_values` then asks cfprefsd, as before this
    check existed)."""
    name = plist_path.name
    for group in sorted(entitled_app_groups()):
        if name != f"{group}.plist":
            continue
        inside = Path("Library") / "Group Containers" / group / "Library" / "Preferences" / name
        real_home = _real_home()
        if not _is_under_home(plist_path, inside, real_home):
            return real_home / inside
    return None


def _is_under_home(plist_path: Path, inside: Path, real_home: Path) -> bool:
    """Whether `plist_path` is `inside` under the folder `real_home`, however
    that folder is spelled: through a symlink, in another letter case (APFS
    usually ignores case, `realpath` does not), or through a firmlink such as
    `/System/Volumes/Data/Users/…` (which `realpath` does not resolve either).
    So the two home folders are compared as folders, by device and inode.

    Only the two home folders are looked at, never anything inside a
    container: opening the container from a launchd process that has no
    approval for it is what hung in the kernel in v1.30.2. Raises when the
    user's own home cannot be looked at (cannot tell). A home folder in the
    path that does not exist, or cannot be looked at, is not the user's."""
    path = Path(os.path.normpath(plist_path))
    tail = len(inside.parts)
    if len(path.parts) <= tail or path.parts[-tail:] != inside.parts:
        return False
    home = Path(*path.parts[:-tail])
    if home == Path(os.path.normpath(real_home)):
        return True
    real = os.stat(real_home)
    try:
        other = os.stat(home)
    except OSError:
        return False
    return (other.st_dev, other.st_ino) == (real.st_dev, real.st_ino)


def copy_values(plist_path: Path, keys: Iterable[str]) -> dict | None:
    """What cfprefsd holds for `keys` in the defaults domain stored at
    `plist_path`. Keys with no value are left out. None when this cannot ask
    cfprefsd, or when no key has a value (the caller then reads the file,
    which alone can tell a missing file from an unreadable one). None too when
    `plist_path` would name another file's domain to this process (an entitled
    helper under a HOME that is not the user's, see the module doc): cfprefsd
    is not asked then, so the file answers. Never raises.
    """
    if not ENABLED:
        return None
    cf = _load()
    if cf is None:
        return None
    try:
        real = _real_container_plist(plist_path)
    except Exception as exc:  # noqa: BLE001 — cannot tell: ask, as before
        logger.debug("cannot tell which domain %s names: %s", plist_path, exc)
        real = None
    if real is not None:
        if str(plist_path) not in _not_asked:
            _not_asked.add(str(plist_path))
            logger.info(
                "not asking cfprefsd for %s: this process is entitled to that app group, "
                "so cfprefsd would answer for the user's real container (%s) instead of "
                "this file; reading the file",
                plist_path, real,
            )
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
