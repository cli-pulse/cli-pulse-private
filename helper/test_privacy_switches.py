"""The Companion CLI obeys Settings › Privacy's Claude keychain switches.

"Strict privacy mode" and "Skip Claude Code keychain access" were saved only in
the Mac app's own defaults, so this helper went on reading Claude Code's
keychain item ("Claude Code-credentials") whatever they said. From 1.55 the app
copies both into its app group, and these tests check that:

  * the decision for every copy: none (an app older than 1.55), each switch,
    both off, and a copy that cannot be read;
  * the plist reader carries the two keys, and asks cfprefsd before the file
    (on a Mac: written through CFPreferences as the app writes them, read back
    straight after each write);
  * Claude's quota read (`system_collector._fetch_claude_usage`) and a managed
    session's token (`claude_oauth.read_claude_oauth`) skip the item when a
    switch is on, and read it when both are off (the negative control for
    each); a token read from the item before the switch turned on is not
    reused;
  * the daemon and the `heartbeat` / `sync` / `run-demo` subcommands install
    the gate, and the daemon takes it down on the way out;
  * the helper logs what it does once per change;
  * the UDS `hello` obeys the app's own `local_scan_allowed: false`.
"""
from __future__ import annotations

import argparse
import ctypes
import plistlib
import subprocess
import sys
import types
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import app_group_prefs  # noqa: E402
import claude_oauth as co  # noqa: E402
import cli_pulse_helper as h  # noqa: E402
import local_scan_consent as lsc  # noqa: E402
import provider_spawners  # noqa: E402
import system_collector as sc  # noqa: E402
from local_scan_consent import LocalScanGate, MirrorRead  # noqa: E402
from privacy_switches import ClaudeKeychainGate, decide_claude_keychain  # noqa: E402

# Where the app's `UserDefaults(suiteName: "group.yyh.CLI-Pulse")` lives.
MIRROR = Path("Library/Group Containers/group.yyh.CLI-Pulse/Library/Preferences/group.yyh.CLI-Pulse.plist")
SKIP = "cli_pulse_privacy_skip_claude_keychain"
STRICT = "cli_pulse_privacy_local_only_mode"
KEYCHAIN_ARGV = ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


def write_mirror(home: Path, values: dict) -> Path:
    path = home / MIRROR
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        plistlib.dump(values, fh, fmt=plistlib.FMT_BINARY)
    return path


def switches(skip: bool, strict: bool, **extra) -> dict:
    # The app writes both keys every time (`HelperPrivacyInputs.mirror`).
    return {SKIP: skip, STRICT: strict, "cli_pulse_local_scan_consent": "granted", **extra}


def test_keys_are_the_ones_the_app_writes():
    # HelperPrivacyInputs.swift spells the same strings; a rename there fails
    # HelperPrivacyInputsTests.testKeysAreTheOnesTheCompanionCLIReads.
    assert lsc.SKIP_CLAUDE_KEYCHAIN_KEY == SKIP
    assert lsc.LOCAL_ONLY_MODE_KEY == STRICT
    assert SKIP in lsc.MIRROR_KEYS and STRICT in lsc.MIRROR_KEYS


# ── the decision ───────────────────────────────────────────────


@pytest.mark.parametrize(
    ("read", "allowed", "reason"),
    [
        # No copy: an app older than 1.55. As before.
        (MirrorRead("absent"), True, "no_copy"),
        (MirrorRead("ok"), True, "no_copy"),
        (MirrorRead("ok", consent="granted"), True, "no_copy"),
        # The switches.
        (MirrorRead("ok", skip_claude_keychain=False, local_only_mode=False), True, "allowed"),
        (MirrorRead("ok", skip_claude_keychain=True, local_only_mode=False), False, "skip_claude_keychain"),
        (MirrorRead("ok", skip_claude_keychain=True, local_only_mode=True), False, "strict_privacy_mode"),
        (MirrorRead("ok", skip_claude_keychain=False, local_only_mode=True), False, "strict_privacy_mode"),
        # Half a copy still says what it says.
        (MirrorRead("ok", skip_claude_keychain=True), False, "skip_claude_keychain"),
        (MirrorRead("ok", local_only_mode=True), False, "strict_privacy_mode"),
        # A copy that cannot be read may hold a yes.
        (MirrorRead("unreadable", detail="EPERM"), False, "unreadable"),
    ],
)
def test_decision_for_every_copy(read, allowed, reason):
    decision = decide_claude_keychain(read)
    assert (decision.allowed, decision.reason) == (allowed, reason)


def test_the_file_reader_carries_the_switches(home):
    assert lsc.read_mirror().status == "absent"
    write_mirror(home, {"cli_pulse_local_scan_consent": "granted"})
    read = lsc.read_mirror()
    assert (read.skip_claude_keychain, read.local_only_mode) == (None, None)
    write_mirror(home, switches(True, False))
    read = lsc.read_mirror()
    assert (read.skip_claude_keychain, read.local_only_mode, read.source) == (True, False, "file")
    # `UserDefaults.bool(forKey:)` semantics, as for the sign-in record.
    write_mirror(home, {SKIP: "YES", STRICT: 0})
    read = lsc.read_mirror()
    assert (read.skip_claude_keychain, read.local_only_mode) == (True, False)


# ── the gate ───────────────────────────────────────────────────


def test_the_gate_reads_the_copy_at_every_check(home):
    gate = ClaudeKeychainGate(LocalScanGate().read)
    assert gate.check().reason == "no_copy"
    write_mirror(home, switches(False, False))
    assert gate.allows("test") is True
    write_mirror(home, switches(True, False))
    assert gate.allows("test") is False
    write_mirror(home, switches(True, True))
    assert gate.check().reason == "strict_privacy_mode"
    write_mirror(home, switches(False, False))
    assert gate.allows("test") is True


def test_a_reader_that_fails_skips_the_item():
    def broken(**_kw):
        raise OSError("EPERM")

    decision = ClaudeKeychainGate(broken).check()
    assert (decision.allowed, decision.reason) == (False, "unreadable")
    assert "EPERM" in decision.detail


def test_a_stuck_container_skips_the_item(home):
    write_mirror(home, switches(False, False))
    gate = ClaudeKeychainGate(LocalScanGate(container_ready=lambda: False).read)
    assert gate.check().reason == "unreadable"


def test_the_gate_logs_a_change_once(home, caplog):
    caplog.set_level("INFO", logger="cli_pulse.privacy_switches")
    gate = ClaudeKeychainGate(LocalScanGate().read)
    write_mirror(home, switches(False, True))
    for _ in range(3):
        gate.check()
    write_mirror(home, switches(False, False))
    for _ in range(3):
        gate.check()
    messages = [r.getMessage() for r in caplog.records if r.name == "cli_pulse.privacy_switches"]
    assert messages == [
        "Claude Code keychain item: skipped (Strict privacy mode is on in the app)",
        "Claude Code keychain item: read when needed (both Privacy switches are off in the app)",
    ]


# ── Claude's quota read ────────────────────────────────────────


@pytest.fixture
def claude_usage(monkeypatch):
    """`_fetch_claude_usage` with every step after the keychain stubbed, and
    the keychain read recorded instead of run."""
    calls: list[list[str]] = []
    creds = '{"claudeAiOauth": {"accessToken": "sk-ant-oat01-KC", "expiresAt": 9999999999000}}'

    def fake_run(argv, *a, **k):
        calls.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, stdout=creds, stderr="")

    monkeypatch.setattr(sc.subprocess, "run", fake_run)
    monkeypatch.setattr(sc, "_fetch_claude_oauth_api", lambda token, plan: {"token": token})
    monkeypatch.setattr(sc, "_write_claude_snapshot", lambda *a, **k: None)
    monkeypatch.setattr(sc, "_fetch_claude_web_usage", lambda plan: None)
    monkeypatch.setattr(sc, "_fetch_claude_cli", lambda plan: None)
    return calls


def test_without_a_gate_the_quota_read_opens_the_item(claude_usage):
    # Negative control: what every cycle did before 1.55, whatever the switches.
    assert sc._fetch_claude_usage() == {"token": "sk-ant-oat01-KC"}
    assert claude_usage == [KEYCHAIN_ARGV]


@pytest.mark.parametrize("values", [switches(True, False), switches(False, True), switches(True, True)])
def test_a_switch_on_skips_the_item_for_the_quota_read(home, claude_usage, values):
    write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._fetch_claude_usage() is None  # no token, and web + CLI found nothing
    assert claude_usage == []


@pytest.mark.parametrize("values", [switches(False, False), None])
def test_both_off_or_an_older_app_reads_the_item_as_before(home, claude_usage, values):
    if values is not None:
        write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._fetch_claude_usage() == {"token": "sk-ant-oat01-KC"}
    assert claude_usage == [KEYCHAIN_ARGV]


def test_a_gate_that_raises_skips_the_item(claude_usage):
    sc.set_claude_keychain_gate(lambda _what: 1 / 0)
    assert sc._fetch_claude_usage() is None
    assert claude_usage == []


# ── a managed Claude session's token ───────────────────────────


@pytest.fixture
def token_sources(tmp_path, monkeypatch):
    """No credential file refresh token, and a keychain item that has one: the
    case where `read_claude_oauth` falls back to the item."""
    co._reset_cache_for_testing()
    creds = tmp_path / ".credentials.json"
    creds.write_text('{"claudeAiOauth": {"accessToken": "sk-ant-oat01-FILE", "refreshToken": ""}}')
    monkeypatch.setattr(co, "_CREDENTIALS_FILE", str(creds))
    opened: list[int] = []

    def keychain():
        opened.append(1)
        return {"accessToken": "sk-ant-oat01-KC", "refreshToken": "sk-ant-ort01-KCR",
                "expiresAt": 9_999_999_999_000}

    monkeypatch.setattr(co, "_read_keychain_oauth", keychain)
    yield opened
    co._reset_cache_for_testing()


def test_without_a_gate_the_session_token_falls_back_to_the_item(token_sources):
    oauth, source = co.read_claude_oauth()
    assert source == "keychain"
    assert token_sources == [1]


@pytest.mark.parametrize("values", [switches(True, False), switches(False, True)])
def test_a_switch_on_keeps_the_session_token_to_the_file(home, token_sources, values):
    write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    oauth, source = co.read_claude_oauth()
    assert source == "file" and co._access_of(oauth) == "sk-ant-oat01-FILE"
    assert token_sources == []


def test_both_off_the_session_token_may_come_from_the_item(home, token_sources):
    write_mirror(home, switches(False, False))
    h._install_claude_keychain_gate(LocalScanGate())
    assert co.read_claude_oauth()[1] == "keychain"
    assert token_sources == [1]


def test_a_token_read_from_the_item_is_not_reused_once_a_switch_is_on(home, token_sources):
    write_mirror(home, switches(False, False))
    h._install_claude_keychain_gate(LocalScanGate())
    assert co.resolve_fresh_claude_access_token() == "sk-ant-oat01-KC"
    assert token_sources == [1]
    # The same token again, from the cache: nothing read.
    assert co.resolve_fresh_claude_access_token() == "sk-ant-oat01-KC"
    assert token_sources == [1]

    write_mirror(home, switches(True, False))
    # Only the file is left: its token has no expiry, so it is used as-is.
    assert co.resolve_fresh_claude_access_token() == "sk-ant-oat01-FILE"
    assert token_sources == [1]


def test_a_token_from_the_file_stays_cached_when_a_switch_turns_on(home, token_sources):
    creds = Path(co._CREDENTIALS_FILE)
    creds.write_text(
        '{"claudeAiOauth": {"accessToken": "sk-ant-oat01-FILE", "refreshToken": "sk-ant-ort01-F",'
        ' "expiresAt": 9999999999000}}'
    )
    write_mirror(home, switches(False, False))
    h._install_claude_keychain_gate(LocalScanGate())
    assert co.resolve_fresh_claude_access_token() == "sk-ant-oat01-FILE"
    write_mirror(home, switches(True, True))
    creds.unlink()  # a cache miss would now find nothing
    assert co.resolve_fresh_claude_access_token() == "sk-ant-oat01-FILE"
    assert token_sources == []


# ── wiring ─────────────────────────────────────────────────────


def test_installing_the_gate_wires_both_reads_to_the_same_copy(home, token_sources, claude_usage):
    write_mirror(home, switches(True, False))
    gate = h._install_claude_keychain_gate(LocalScanGate())
    assert isinstance(gate, ClaudeKeychainGate)
    assert sc._claude_keychain_gate is not None and co._keychain_gate is not None
    assert sc._claude_keychain_allowed("test") is False
    assert co._keychain_allowed() is False
    h._uninstall_claude_keychain_gate()
    assert sc._claude_keychain_gate is None and co._keychain_gate is None


@pytest.mark.parametrize(("argv", "names"), [
    (["heartbeat"], ("heartbeat",)),
    (["sync"], ("sync",)),
    (["run-demo", "--cycles", "1", "--interval", "0"], ("heartbeat", "sync")),
])
def test_subcommands_that_collect_install_the_gate(home, monkeypatch, argv, names):
    write_mirror(home, switches(False, True))
    seen: dict[str, object] = {}
    for name in names:
        def _record(_args, gate=None, _name=name):
            seen[_name] = (sc._claude_keychain_allowed("test"), co._keychain_allowed())
            return False
        monkeypatch.setattr(h, name, _record)
    monkeypatch.setattr(sys, "argv", ["cli_pulse_helper", *argv])
    monkeypatch.setattr(h.time, "sleep", lambda _s: None)
    h.main()
    assert seen == {name: (False, False) for name in names}


def _fail_config():
    raise h.ConfigError("not paired (test)")


def test_the_daemon_installs_the_gate_and_takes_it_down(home, monkeypatch):
    import signal

    write_mirror(home, switches(True, False))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    seen: dict = {}

    def one_cycle(_args, **_kwargs):
        seen["quota"] = sc._claude_keychain_allowed("test")
        seen["session"] = co._keychain_allowed()
        raise KeyboardInterrupt  # ends the daemon after its first cycle

    monkeypatch.setattr(h, "_collection_cycle", one_cycle)
    h.daemon(argparse.Namespace(interval=60))
    assert seen == {"quota": False, "session": False}
    assert sc._claude_keychain_gate is None and co._keychain_gate is None


# ── hello: the app's own answer ────────────────────────────────


def _hello(params: dict, local_scan_allowed=None) -> dict:
    from local_session_server import LocalSessionServer

    def _unused(*_a, **_k):
        raise AssertionError("hello must not reach the session manager")

    server = LocalSessionServer(
        socket_path="/nonexistent/clipulse-helper.sock",
        get_auth_token=lambda: "T",
        get_local_control_enabled=lambda: True,
        set_local_control_enabled=_unused,
        start_session=_unused,
        list_sessions=_unused,
        stop_session=_unused,
        send_input=_unused,
        local_scan_allowed=local_scan_allowed,
    )
    return server._handle_method("hello", params)


def test_hello_obeys_the_apps_no_before_its_own_copy(monkeypatch):
    def fail():
        raise AssertionError("provider_plan_statuses opened ~/.codex/auth.json after the app said no")

    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", fail)
    asked: list[int] = []
    reply = _hello({"local_scan_allowed": False}, local_scan_allowed=lambda: asked.append(1) or True)
    assert "provider_plan_status" not in reply
    assert asked == []  # not even this helper's own copy is read


@pytest.mark.parametrize("params", [{"local_scan_allowed": True}, {}, {"local_scan_allowed": None}])
def test_hello_without_the_apps_no_follows_its_own_copy(monkeypatch, params):
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", lambda: {"codex": "off_plan"})
    assert _hello(params, local_scan_allowed=lambda: True)["provider_plan_status"] == {"codex": "off_plan"}
    assert "provider_plan_status" not in _hello(params, local_scan_allowed=lambda: False)


# ── cfprefsd first (macOS) ─────────────────────────────────────

darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="CFPreferences is macOS-only")


def test_the_reader_is_off_when_disabled(tmp_path):
    # conftest.py turns it off for the suite; the file is then the answer.
    assert app_group_prefs.ENABLED is False
    assert app_group_prefs.copy_values(tmp_path / "x.plist", [SKIP]) is None


class _CFWriter:
    """Writes through CFPreferences the way `UserDefaults.set` does: to
    cfprefsd, without synchronizing, so the plist file lags behind."""

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

    def _str(self, text: str):
        return self.cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)

    def set(self, key: str, value) -> None:
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

    def flush(self) -> None:
        self.cf.CFPreferencesAppSynchronize(self.app)


@darwin_only
def test_the_reader_answers_with_what_was_just_written(tmp_path, monkeypatch):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    path = tmp_path / "group.yyh.CLI-Pulse.plist"
    writer = _CFWriter(path)
    try:
        for i in range(10):
            strict = i % 2 == 0
            writer.set(STRICT, strict)
            writer.set(SKIP, not strict)
            writer.set("cli_pulse_local_scan_consent", "declined" if strict else "granted")
            read = lsc.read_mirror(path)
            assert read.source == "cfprefsd"
            assert (read.local_only_mode, read.skip_claude_keychain) == (strict, not strict), i
            assert read.consent == ("declined" if strict else "granted"), i
            assert decide_claude_keychain(read).reason == (
                "strict_privacy_mode" if strict else "skip_claude_keychain"
            )
    finally:
        for key in (STRICT, SKIP, "cli_pulse_local_scan_consent"):
            writer.set(key, None)
        writer.flush()


@darwin_only
def test_the_reader_converts_what_it_reads(tmp_path, monkeypatch):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    path = tmp_path / "types.plist"
    writer = _CFWriter(path)
    try:
        writer.set("b", True)
        writer.set("s", "undecided ✓")
        writer.set("n", 7)
        writer.set("d", b"\x00\x01")
        values = app_group_prefs.copy_values(path, ["b", "s", "n", "d", "missing"])
        assert values["b"] is True
        assert values["s"] == "undecided ✓"
        assert values["n"] == 7
        assert isinstance(values["d"], app_group_prefs.Unsupported)
        assert "missing" not in values
        # Nothing there at all: None, so the caller reads the file.
        assert app_group_prefs.copy_values(path, ["missing"]) is None
    finally:
        for key in ("b", "s", "n", "d"):
            writer.set(key, None)
        writer.flush()


@darwin_only
def test_with_nothing_in_cfprefsd_the_file_is_read(home, monkeypatch):
    # A pre-1.55 app, or a process cfprefsd will not answer: the file decides,
    # and a missing file is still "absent" rather than "unreadable".
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    assert lsc.read_mirror().status == "absent"


def test_a_failing_cfprefsd_read_falls_back_to_the_file(home, monkeypatch):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    monkeypatch.setattr(app_group_prefs, "_load", lambda: types.SimpleNamespace())  # every call raises
    write_mirror(home, switches(True, False))
    read = lsc.read_mirror()
    assert (read.source, read.skip_claude_keychain) == ("file", True)
