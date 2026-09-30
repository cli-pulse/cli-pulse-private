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
  * the UDS `hello` obeys the app's own `local_scan_allowed: false`;
  * Strict privacy mode also stops the claude.ai fallback that opens browsers'
    cookie stores and reads their "Safe Storage" keychain items: nothing is
    listed, opened or read, checked against a real Chromium-style cookie store
    that the same code does decrypt when the switch is off (the negative
    control). "Skip Claude Code keychain access" alone does not stop it.
"""
from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
import types
from pathlib import Path

import pytest
from conftest import darwin_only

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
from privacy_switches import (  # noqa: E402
    BrowserCookieGate,
    ClaudeKeychainGate,
    decide_browser_cookies,
    decide_claude_keychain,
)

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


def test_cfprefsd_is_asked_for_every_key_the_copy_is_read_for():
    # The cfprefsd reader asks for `MIRROR_KEYS` only, and both readers return
    # no others, so a key constant missing from it is a key never read.
    constants = {value for name, value in vars(lsc).items() if name.endswith("_KEY")}
    assert constants == set(lsc.MIRROR_KEYS)


def test_the_file_reader_sees_no_more_than_cfprefsd_is_asked_for(home):
    # A key outside `MIRROR_KEYS` in the file is not read, as cfprefsd would
    # not be asked for it: the tests, which mostly read the file, see what
    # production sees.
    all_keys = {
        "cli_pulse_local_scan_consent": "granted",
        "cli_pulse_app_account": "local_mode",
        SKIP: True,
        STRICT: False,
    }
    write_mirror(home, all_keys)
    read = lsc.read_mirror()
    assert (read.consent, read.account, read.skip_claude_keychain, read.local_only_mode) == (
        "granted", "local_mode", True, False,
    )
    original = lsc.MIRROR_KEYS
    for dropped in original:
        lsc.MIRROR_KEYS = tuple(key for key in original if key != dropped)
        try:
            read = lsc.read_mirror()
        finally:
            lsc.MIRROR_KEYS = original
        fields = {
            "cli_pulse_local_scan_consent": read.consent,
            "cli_pulse_app_account": read.account,
            SKIP: read.skip_claude_keychain,
            STRICT: read.local_only_mode,
        }
        assert fields[dropped] is None, dropped


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


def test_the_gate_reads_the_copy_at_every_check(home, app_group_copy):
    # Through the file and, on a Mac, through cfprefsd as the app writes it.
    gate = ClaudeKeychainGate(LocalScanGate().read)
    assert gate.check().reason == "no_copy"
    app_group_copy.write(switches(False, False))
    assert gate.allows("test") is True
    app_group_copy.write(switches(True, False))
    assert gate.allows("test") is False
    app_group_copy.write(switches(True, True))
    assert gate.check().reason == "strict_privacy_mode"
    app_group_copy.write(switches(False, True))
    assert gate.check().reason == "strict_privacy_mode"
    app_group_copy.write(switches(False, False))
    assert gate.allows("test") is True
    assert lsc.read_mirror().source == app_group_copy.source


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
    # "Skip Claude Code keychain access" names Claude Code's item only.
    assert sc._browser_cookie_gate is not None
    assert sc._browser_cookies_allowed("test") is True
    write_mirror(home, switches(True, True))
    assert sc._browser_cookies_allowed("test") is False
    h._uninstall_claude_keychain_gate()
    assert sc._claude_keychain_gate is None and co._keychain_gate is None
    assert sc._browser_cookie_gate is None


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
            seen[_name] = (
                sc._claude_keychain_allowed("test"),
                co._keychain_allowed(),
                sc._browser_cookies_allowed("test"),
            )
            return False
        monkeypatch.setattr(h, name, _record)
    monkeypatch.setattr(sys, "argv", ["cli_pulse_helper", *argv])
    monkeypatch.setattr(h.time, "sleep", lambda _s: None)
    h.main()
    assert seen == {name: (False, False, False) for name in names}


def _fail_config():
    raise h.ConfigError("not paired (test)")


def test_the_daemon_installs_the_gate_and_takes_it_down(home, monkeypatch):
    import signal

    write_mirror(home, switches(True, True))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    seen: dict = {}

    def one_cycle(_args, **_kwargs):
        seen["quota"] = sc._claude_keychain_allowed("test")
        seen["session"] = co._keychain_allowed()
        seen["browsers"] = sc._browser_cookies_allowed("test")
        raise KeyboardInterrupt  # ends the daemon after its first cycle

    monkeypatch.setattr(h, "_collection_cycle", one_cycle)
    h.daemon(argparse.Namespace(interval=60))
    assert seen == {"quota": False, "session": False, "browsers": False}
    assert sc._claude_keychain_gate is None and co._keychain_gate is None
    assert sc._browser_cookie_gate is None


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

def test_the_reader_is_off_when_disabled(tmp_path):
    # conftest.py turns it off for the suite; the file is then the answer.
    assert app_group_prefs.ENABLED is False
    assert app_group_prefs.copy_values(tmp_path / "x.plist", [SKIP]) is None


@darwin_only
def test_the_reader_answers_with_what_was_just_written(tmp_path, monkeypatch, cfprefs_writer):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    path = tmp_path / "group.yyh.CLI-Pulse.plist"
    writer = cfprefs_writer(path)
    # Each write is left unsynchronized, as `UserDefaults.set` leaves it.
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


@darwin_only
def test_the_reader_converts_what_it_reads(tmp_path, monkeypatch, cfprefs_writer):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)
    path = tmp_path / "types.plist"
    writer = cfprefs_writer(path)
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


# ── Strict privacy mode and the browsers' cookie stores ────────


@pytest.mark.parametrize(
    ("read", "allowed", "reason"),
    [
        # No copy: an app older than 1.55. As before.
        (MirrorRead("absent"), True, "no_copy"),
        (MirrorRead("ok"), True, "no_copy"),
        (MirrorRead("ok", consent="granted"), True, "no_copy"),
        # Strict privacy mode alone decides it.
        (MirrorRead("ok", skip_claude_keychain=False, local_only_mode=False), True, "allowed"),
        (MirrorRead("ok", skip_claude_keychain=True, local_only_mode=False), True, "allowed"),
        (MirrorRead("ok", skip_claude_keychain=True, local_only_mode=True), False, "strict_privacy_mode"),
        (MirrorRead("ok", skip_claude_keychain=False, local_only_mode=True), False, "strict_privacy_mode"),
        (MirrorRead("ok", local_only_mode=True), False, "strict_privacy_mode"),
        (MirrorRead("ok", skip_claude_keychain=True), True, "allowed"),
        # A copy that cannot be read may hold Strict privacy mode.
        (MirrorRead("unreadable", detail="EPERM"), False, "unreadable"),
    ],
)
def test_browser_decision_for_every_copy(read, allowed, reason):
    decision = decide_browser_cookies(read)
    assert (decision.allowed, decision.reason) == (allowed, reason)


def test_the_browser_gate_reads_the_copy_at_every_check(home, app_group_copy):
    # Through the file and, on a Mac, through cfprefsd as the app writes it.
    gate = BrowserCookieGate(LocalScanGate().read)
    assert gate.check().reason == "no_copy"
    app_group_copy.write(switches(False, True))
    assert gate.allows("test") is False
    app_group_copy.write(switches(True, False))
    assert gate.allows("test") is True
    app_group_copy.write(switches(True, True))
    assert gate.check().reason == "strict_privacy_mode"
    app_group_copy.write(switches(False, False))
    assert gate.allows("test") is True
    assert lsc.read_mirror().source == app_group_copy.source


def test_a_browser_gate_whose_reader_fails_reads_nothing(home):
    def broken(**_kw):
        raise OSError("EPERM")

    assert BrowserCookieGate(broken).check().reason == "unreadable"
    write_mirror(home, switches(False, False))
    stuck = BrowserCookieGate(LocalScanGate(container_ready=lambda: False).read)
    assert stuck.check().reason == "unreadable"


def test_the_browser_gate_logs_a_change_once(home, caplog):
    caplog.set_level("INFO", logger="cli_pulse.privacy_switches")
    gate = BrowserCookieGate(LocalScanGate().read)
    write_mirror(home, switches(True, True))
    for _ in range(3):
        gate.check()
    write_mirror(home, switches(True, False))
    for _ in range(3):
        gate.check()
    messages = [r.getMessage() for r in caplog.records if r.name == "cli_pulse.privacy_switches"]
    assert messages == [
        "Browser cookie stores and their Safe Storage keychain items: skipped "
        "(Strict privacy mode is on in the app)",
        "Browser cookie stores and their Safe Storage keychain items: read when "
        "needed for claude.ai (Strict privacy mode is off in the app)",
    ]


SAFE_STORAGE_PASSWORD = "peanuts-test"
SESSION_KEY = "sk-ant-sid01-TEST-ONLY"


def _chromium_cookie_store(path: Path, value: str, password: str) -> None:
    """A Chromium `Cookies` database holding one claude.ai `sessionKey`,
    encrypted the way Chrome on macOS encrypts it ("v10": AES-128-CBC, key
    from PBKDF2 over the browser's "Safe Storage" password)."""
    import sqlite3

    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import hashes, padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

    key = PBKDF2HMAC(
        algorithm=hashes.SHA1(), length=16, salt=b"saltysalt", iterations=1003,
        backend=default_backend(),
    ).derive(password.encode())
    padder = padding.PKCS7(128).padder()
    plain = padder.update(value.encode()) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(b" " * 16), backend=default_backend()).encryptor()
    blob = b"v10" + encryptor.update(plain) + encryptor.finalize()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as conn:
        conn.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, encrypted_value BLOB)")
        conn.execute("INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', ?)", (blob,))


@pytest.fixture
def browser_store(home, monkeypatch):
    """A Chrome profile's cookie store under HOME, where
    `_claude_cookie_candidates` looks, and a keychain that answers for
    "Chrome Safe Storage". Records every keychain read, every cookie store the
    helper opens, and whether it listed the stores at all."""
    store = home / "Library" / "Application Support" / "Google" / "Chrome" / "Default" / "Cookies"
    _chromium_cookie_store(store, SESSION_KEY, SAFE_STORAGE_PASSWORD)
    seen: dict[str, list] = {"keychain": [], "opened": [], "listed": []}

    def fake_run(argv, *a, **k):
        seen["keychain"].append(list(argv))
        if argv[:2] == ["security", "find-generic-password"] and "Chrome Safe Storage" in argv:
            return subprocess.CompletedProcess(argv, 0, stdout=SAFE_STORAGE_PASSWORD + "\n", stderr="")
        return subprocess.CompletedProcess(argv, 44, stdout="", stderr="not found")

    real_connect = sc.sqlite3.connect

    def spy_connect(target, *a, **k):
        seen["opened"].append(str(target))
        return real_connect(target, *a, **k)

    real_candidates = sc._claude_cookie_candidates

    def spy_candidates():
        found = real_candidates()
        seen["listed"].append([str(p) for _label, p, _services in found])
        return found

    def no_network(request, *a, **k):
        # A cookie that got through is used against claude.ai; nothing may
        # leave this machine in a test, whichever way it goes.
        seen.setdefault("requests", []).append(getattr(request, "full_url", str(request)))
        raise sc.urllib.error.URLError("no network in tests")

    monkeypatch.setattr(sc.subprocess, "run", fake_run)
    monkeypatch.setattr(sc.sqlite3, "connect", spy_connect)
    monkeypatch.setattr(sc, "_claude_cookie_candidates", spy_candidates)
    monkeypatch.setattr(sc.urllib.request, "urlopen", no_network)
    return seen


def test_without_a_gate_the_claude_fallback_reads_the_browser(browser_store):
    # Negative control: the store and keychain the tests below keep closed are
    # real enough that this code decrypts the cookie from them.
    assert sc._resolve_claude_session_key() == (SESSION_KEY, "chrome:Default")
    assert browser_store["listed"] and browser_store["opened"]
    assert any("Chrome Safe Storage" in argv for argv in browser_store["keychain"])


@pytest.mark.parametrize("values", [switches(False, True), switches(True, True)])
def test_strict_privacy_mode_opens_no_browser_store_and_reads_no_safe_storage(home, browser_store, values):
    write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._resolve_claude_session_key() is None
    assert browser_store == {"keychain": [], "opened": [], "listed": []}


@pytest.mark.parametrize("values", [switches(False, False), switches(True, False), None])
def test_without_strict_privacy_mode_the_fallback_reads_as_before(home, browser_store, values):
    # Off, "Skip Claude Code keychain access" alone, or an app older than 1.55.
    if values is not None:
        write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._resolve_claude_session_key() == (SESSION_KEY, "chrome:Default")
    assert any("Chrome Safe Storage" in argv for argv in browser_store["keychain"])


def test_a_browser_gate_that_raises_reads_nothing(browser_store):
    sc.set_browser_cookie_gate(lambda _what: 1 / 0)
    assert sc._resolve_claude_session_key() is None
    assert browser_store == {"keychain": [], "opened": [], "listed": []}


def test_strict_privacy_mode_reads_no_other_apps_secret_for_claudes_quota(home, browser_store, monkeypatch):
    # The whole quota read, with its OAuth, web and CLI steps: under Strict
    # privacy mode no keychain item is read at all (Claude Code's item, or a
    # browser's Safe Storage item), and no browser store is opened.
    monkeypatch.setattr(sc, "_fetch_claude_cli", lambda plan: None)
    monkeypatch.setattr(sc, "_write_claude_snapshot", lambda *a, **k: None)
    monkeypatch.setattr(sc, "_write_claude_session_key", lambda *a, **k: None)
    write_mirror(home, switches(True, True))
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._fetch_claude_usage() is None
    assert browser_store == {"keychain": [], "opened": [], "listed": []}


# ── Strict privacy mode and the claude.ai cookie copied earlier ─


def _copied_cookie_files(home: Path) -> list[Path]:
    """`claude_session.json` where `_write_claude_session_key` puts it, each
    holding a cookie an earlier cycle took from a browser."""
    files = [
        home / "Library" / "Group Containers" / "group.yyh.CLI-Pulse" / "claude_session.json",
        home / ".clipulse" / "claude_session.json",
    ]
    for path in files:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"sessionKey": "%s", "source": "chrome:Default"}' % SESSION_KEY)
    return files


def test_the_cookie_files_are_where_the_writer_puts_them(home, monkeypatch):
    # The test above writes the files by hand; the writer must agree on where.
    monkeypatch.setattr(sc, "_cycle_still_allowed", lambda _what: True)
    sc._write_claude_session_key(SESSION_KEY, "chrome:Default")
    written = sorted(str(p) for p in home.rglob("claude_session.json"))
    assert written == sorted(str(p) for p in _copied_cookie_files(home))


def test_strict_privacy_mode_removes_the_cookie_copied_earlier(home):
    files = _copied_cookie_files(home)
    write_mirror(home, switches(True, True))
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc.forget_claude_session_key_under_strict_privacy_mode() is True
    assert [p.exists() for p in files] == [False, False]
    # Nothing left to remove is no error.
    assert sc.forget_claude_session_key_under_strict_privacy_mode() is True


@pytest.mark.parametrize(
    "values",
    [
        switches(False, False),
        # "Skip Claude Code keychain access" names Claude Code's item only.
        switches(True, False),
        # No copy: an app older than 1.55.
        None,
    ],
)
def test_without_strict_privacy_mode_the_cookie_copied_earlier_stays(home, values):
    # Negative control for the test above.
    files = _copied_cookie_files(home)
    if values is not None:
        write_mirror(home, values)
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc.forget_claude_session_key_under_strict_privacy_mode() is False
    assert [p.exists() for p in files] == [True, True]


def test_an_unreadable_copy_leaves_the_cookie_copied_earlier(home):
    # "Do not read" is not "Strict privacy mode": a copy that cannot be read
    # stops the browser reads, but only the switch removes the file.
    files = _copied_cookie_files(home)
    write_mirror(home, switches(True, True))
    h._install_claude_keychain_gate(LocalScanGate(container_ready=lambda: False))
    assert sc._browser_cookies_allowed("test") is False
    assert sc.forget_claude_session_key_under_strict_privacy_mode() is False
    assert [p.exists() for p in files] == [True, True]


def test_without_a_gate_nothing_is_removed(home):
    files = _copied_cookie_files(home)
    assert sc.forget_claude_session_key_under_strict_privacy_mode() is False
    assert [p.exists() for p in files] == [True, True]


def test_the_claude_fallback_under_strict_privacy_mode_also_removes_the_old_cookie(home, browser_store):
    files = _copied_cookie_files(home)
    write_mirror(home, switches(False, True))
    h._install_claude_keychain_gate(LocalScanGate())
    assert sc._resolve_claude_session_key() is None
    assert [p.exists() for p in files] == [False, False]
    assert browser_store == {"keychain": [], "opened": [], "listed": []}


def test_no_cookie_is_copied_for_the_app_once_strict_privacy_mode_is_on(home, monkeypatch):
    # The switch turned on between reading the cookie and writing the copy.
    monkeypatch.setattr(sc, "_cycle_still_allowed", lambda _what: True)
    write_mirror(home, switches(False, True))
    h._install_claude_keychain_gate(LocalScanGate())
    sc._write_claude_session_key(SESSION_KEY, "chrome:Default")
    assert list(home.rglob("claude_session.json")) == []
    # Negative control: with the switch off the copy is written.
    write_mirror(home, switches(False, False))
    sc._write_claude_session_key(SESSION_KEY, "chrome:Default")
    assert len(list(home.rglob("claude_session.json"))) == 2


@pytest.mark.parametrize("consent", ["granted", "declined"])
def test_every_cycle_removes_the_old_cookie_under_strict_privacy_mode(home, monkeypatch, consent):
    # At the start of each cycle, whatever the answer: a paused cycle
    # ("Not now") reads nothing on this Mac and sends nothing, and removing
    # the copy is neither.
    files = _copied_cookie_files(home)
    write_mirror(home, switches(True, True, cli_pulse_local_scan_consent=consent))
    gate = LocalScanGate()
    h._install_claude_keychain_gate(gate)
    ran: list[str] = []
    monkeypatch.setattr(h, "heartbeat", lambda *_a, **_k: ran.append("heartbeat"))
    monkeypatch.setattr(h, "sync", lambda *_a, **_k: ran.append("sync"))
    monkeypatch.setattr(h, "_still_allowed", lambda *_a, **_k: False)
    h._collection_cycle(argparse.Namespace(), gate=gate, git=h._GitScanState(), env_force_git=False)
    assert [p.exists() for p in files] == [False, False]
    assert ran == (["heartbeat", "sync"] if consent == "granted" else [])
