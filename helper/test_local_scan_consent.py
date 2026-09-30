"""The Companion CLI honours the Mac app's local-scan answer.

The app (1.55+) copies its answer into its app-group defaults, a cfprefsd plist
in the group container. These tests write that plist where the app does, under
a throwaway HOME, and check what the helper then reads and sends:

  * the decision for every answer, account record (signed in as the pairing's
    user or another, local mode, signed out), and the file being absent, from
    an older app, or unreadable, read from the file and, on a Mac, through
    cfprefsd as the app writes it;
  * that a sign-in uploads only with a pairing made for that user: not paired,
    it answers the app and uploads nothing; a pairing that names no usable
    user pauses, since `load_config` would upload with it;
  * every account record x every answer against what the #626 contract says,
    at the gate, in a daemon cycle that loads the pairing from disk, and at
    `hello` (the section at the end);
  * that the gate reads the file on every check, does not stack a second read on
    a stalled one, and does not touch a container the startup rotation is still
    stuck in;
  * that a paused heartbeat, sync or daemon cycle reads nothing (every collector
    fails the test if called) and sends nothing;
  * that an answer given while a cycle runs drops what the cycle collected,
    before each upload, the git lookup, the commit submit, the Claude snapshot
    write, any Claude or Gemini token refresh (the Gemini one rewrites its
    credential file), and the `claude /usage` fallback;
  * that the UDS `hello` reply reads no credential file for
    `provider_plan_status` while the answer pauses the scan;
  * that the daemon and the `heartbeat` / `sync` / `run-demo` subcommands are
    the ones wired to the gate, and that the daemon's gate waits for a startup
    rotation still stuck in the container.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import sys
import threading
import time
import types
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as h  # noqa: E402
import local_scan_consent as lsc  # noqa: E402
import machine_collector  # noqa: E402
import provider_spawners  # noqa: E402
import sensor_bridge  # noqa: E402
import system_collector as sc  # noqa: E402
from local_scan_consent import Cycle, LocalScanGate, MirrorRead  # noqa: E402

_REAL_LOAD_CONFIG = h.load_config

# Where the app's `UserDefaults(suiteName: "group.yyh.CLI-Pulse")` lives on
# disk, spelled out rather than taken from `mirror_plist_path()`, so that moving
# the path in the module fails here.
MIRROR = Path("Library/Group Containers/group.yyh.CLI-Pulse/Library/Preferences/group.yyh.CLI-Pulse.plist")

# Keys a pre-1.55 app already writes to the same plist. None of them is an answer.
PRE_155_KEYS = {
    "helper_status": b'{"state":"running","helperVersion":"1.0.0"}',
    "widgetData": b"{}",
    "helper_provider_configs": b"[]",
    "provider_accounts_v2_write": True,
}


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert Path.home() == tmp_path
    return tmp_path


def write_mirror(home: Path, values: dict, fmt=plistlib.FMT_BINARY) -> Path:
    path = home / MIRROR
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        plistlib.dump(values, fh, fmt=fmt)
    return path


# The user this Mac's Companion was paired for, and another one.
ME = "6f1c1a52-3b0e-4d7a-9c55-0d9e8f7a6b5c"
OTHER = "0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d"


def answer(consent=None, account=None, **extra) -> dict:
    values = dict(PRE_155_KEYS)
    if consent is not None:
        values["cli_pulse_local_scan_consent"] = consent
    if account is not None:
        values["cli_pulse_app_account"] = account
    values.update(extra)
    return values


def signed_in(user_id: str = ME) -> str:
    return f"signed_in:{user_id}"


def write_pairing(home: Path, user_id: str | None = ME, raw: bytes | None = None) -> Path:
    """`~/.cli-pulse-helper.json`, as `save_config` writes it."""
    path = home / ".cli-pulse-helper.json"
    if raw is None:
        body = {"device_id": "dev-1", "device_name": "Mac", "helper_version": "1", "helper_secret": "s"}
        if user_id is not None:
            body["user_id"] = user_id
        raw = json.dumps(body).encode()
    path.write_bytes(raw)
    return path


def test_the_module_reads_the_path_the_app_writes(home):
    assert lsc.mirror_plist_path() == home / MIRROR


# ── the decision ───────────────────────────────────────────────


@pytest.mark.parametrize(
    ("values", "cycle", "reason"),
    [
        # No copy: an app older than 1.55. Behaves as before.
        (None, Cycle.LEGACY, "no_copy"),
        (dict(PRE_155_KEYS), Cycle.LEGACY, "no_copy"),
        ({}, Cycle.LEGACY, "no_copy"),
        # The answers, from an app that has not recorded an account.
        (answer("declined"), Cycle.PAUSED, "declined"),
        (answer("granted"), Cycle.COLLECT, "granted"),
        (answer("undecided"), Cycle.COLLECT, "undecided"),
        # Signed in (as the pairing's user: see the pairing tests below).
        (answer("declined", signed_in()), Cycle.PAUSED, "declined"),
        (answer("granted", signed_in()), Cycle.COLLECT, "granted"),
        (answer("undecided", signed_in()), Cycle.COLLECT, "undecided"),
        (answer("maybe", signed_in()), Cycle.PAUSED, "unrecognised"),
        # Only a 1.55+ app records an account, so a missing answer beside one
        # is not an older app speaking.
        (answer(account=signed_in()), Cycle.PAUSED, "no_answer"),
        # Signed out: nothing, whatever the answer.
        (answer("granted", "signed_out"), Cycle.PAUSED, "signed_out"),
        (answer("undecided", "signed_out"), Cycle.PAUSED, "signed_out"),
        (answer("declined", "signed_out"), Cycle.PAUSED, "signed_out"),
        (answer(account="signed_out"), Cycle.PAUSED, "signed_out"),
        # An account record this helper does not know reads as signed out, as
        # `HelperAccountRecord(storedValue:)` reads it.
        (answer("granted", "signed_in:"), Cycle.PAUSED, "signed_out"),
        (answer("granted", "signed_in:   "), Cycle.PAUSED, "signed_out"),
        (answer("granted", "guest"), Cycle.PAUSED, "signed_out"),
        (answer("granted", "Signed_Out"), Cycle.PAUSED, "signed_out"),
        (answer("granted", "LOCAL_MODE"), Cycle.PAUSED, "signed_out"),
        (answer("granted", True), Cycle.PAUSED, "signed_out"),
        (answer("granted", 1), Cycle.PAUSED, "signed_out"),
        # Local mode: reads for the app after a yes, uploads nothing.
        (answer("granted", "local_mode"), Cycle.LOCAL, "local_mode"),
        (answer("undecided", "local_mode"), Cycle.PAUSED, "undecided_local_mode"),
        (answer("declined", "local_mode"), Cycle.PAUSED, "declined"),
        (answer("maybe", "local_mode"), Cycle.PAUSED, "unrecognised"),
        (answer(account="local_mode"), Cycle.PAUSED, "no_answer"),
        # A development build once wrote a Bool instead; no release did.
        (answer("granted", cli_pulse_app_signed_out=True), Cycle.COLLECT, "granted"),
        # The older-history answer does not change what this helper may do.
        (answer("granted", cli_pulse_local_scan_consent_v2="declined"), Cycle.COLLECT, "granted"),
        (answer("declined", cli_pulse_local_scan_consent_v2="granted"), Cycle.PAUSED, "declined"),
        # A value this helper does not know is not read as "no copy".
        (answer("maybe"), Cycle.PAUSED, "unrecognised"),
        (answer("Declined"), Cycle.PAUSED, "unrecognised"),
        (answer(1), Cycle.PAUSED, "unrecognised"),
        (answer(True), Cycle.PAUSED, "unrecognised"),
    ],
)
def test_decision_for_every_answer(home, app_group_copy, values, cycle, reason):
    write_pairing(home, ME)  # a sign-in record below is for the pairing's user
    app_group_copy.write(values)
    decision = lsc.decide(lsc.read_mirror())
    assert (decision.cycle, decision.reason) == (cycle, reason)
    assert decision.allows_collection is (cycle is not Cycle.PAUSED)
    assert decision.allows_upload is (cycle in (Cycle.COLLECT, Cycle.LEGACY))


# ── the account record against the pairing ────────────────────


@pytest.mark.parametrize(
    ("values", "cycle", "reason"),
    [
        (answer("granted", signed_in(ME)), Cycle.COLLECT, "granted"),
        (answer("undecided", signed_in(ME)), Cycle.COLLECT, "undecided"),
        # Supabase ids are UUIDs, the same id in either case.
        (answer("granted", signed_in(ME.upper())), Cycle.COLLECT, "granted"),
        # Signed in to another account: its uploads would go to this one.
        (answer("granted", signed_in(OTHER)), Cycle.PAUSED, "other_account"),
        (answer("undecided", signed_in(OTHER)), Cycle.PAUSED, "other_account"),
        (answer(account=signed_in(OTHER)), Cycle.PAUSED, "other_account"),
        # Local mode uploads nothing to the pairing either way.
        (answer("granted", "local_mode"), Cycle.LOCAL, "local_mode"),
        (answer("granted", "signed_out"), Cycle.PAUSED, "signed_out"),
        # No record: the pairing is trusted, as before the record existed.
        (answer("granted"), Cycle.COLLECT, "granted"),
    ],
)
def test_the_account_is_checked_against_the_pairing(home, app_group_copy, values, cycle, reason):
    write_pairing(home, ME)
    app_group_copy.write(values)
    decision = LocalScanGate().check()
    assert (decision.cycle, decision.reason) == (cycle, reason)


@pytest.mark.parametrize(
    ("values", "cycle", "reason"),
    [
        (answer("granted", signed_in(OTHER)), Cycle.LOCAL, "not_paired"),
        (answer("undecided", signed_in(OTHER)), Cycle.LOCAL, "not_paired"),
        (answer("declined", signed_in(OTHER)), Cycle.PAUSED, "declined"),
        (answer("maybe", signed_in(OTHER)), Cycle.PAUSED, "unrecognised"),
        (answer(account=signed_in(OTHER)), Cycle.PAUSED, "no_answer"),
    ],
)
def test_signed_in_and_not_paired_answers_the_app_and_uploads_nothing(home, values, cycle, reason):
    # No pairing file: nothing to upload with. After a yes (or no answer from
    # a signed-in app) it answers the app on this Mac, as the built-in helper
    # does (`collectLocally`), and the cycle stays out of `load_config`.
    write_mirror(home, values)
    assert lsc.paired_user_id_from_config() is None
    decision = LocalScanGate().check()
    assert (decision.cycle, decision.reason) == (cycle, reason)
    assert decision.allows_upload is False


_DROP = object()  # `_loadable_config(key=_DROP)` leaves the key out


def _loadable_config(**fields) -> bytes:
    """A pairing `cli_pulse_helper.load_config` accepts, with `fields` over it."""
    body = {"device_id": "dev-1", "user_id": ME, "device_name": "Mac", "helper_version": "1",
            "helper_secret": "s", "r0_flip_migrated": True}
    body.update(fields)
    return json.dumps({k: v for k, v in body.items() if v is not _DROP}).encode()


@pytest.mark.parametrize(
    "pairing",
    [
        b"{not json",
        b"",
        b"[]",
        b'"u"',
        _loadable_config(user_id=""),
        _loadable_config(user_id="   "),
        _loadable_config(user_id=None),
        _loadable_config(user_id=42),
        _loadable_config(user_id=[ME]),
        _loadable_config(user_id=_DROP),
    ],
    ids=["corrupt", "empty-file", "not-a-dict", "a-string", "empty-user", "blank-user",
         "null-user", "numeric-user", "list-user", "no-user"],
)
@pytest.mark.parametrize("consent", ["granted", "undecided"])
def test_a_pairing_that_names_no_user_pauses_a_sign_in(home, pairing, consent):
    # There is a pairing, but not one this helper can check against the
    # account the app is in. Reading it as "not paired" would let the answer
    # decide, and `load_config` uploads with some of these (see below).
    write_pairing(home, raw=pairing)
    write_mirror(home, answer(consent, signed_in(ME)))
    with pytest.raises(lsc.UnusablePairing):
        lsc.paired_user_id_from_config()
    decision = LocalScanGate().check()
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unverified_pairing")
    assert decision.detail


@pytest.mark.parametrize("make", ["directory", "unreadable"])
def test_a_pairing_that_cannot_be_read_pauses_a_sign_in(home, make):
    path = home / lsc.PAIRING_FILENAME
    if make == "directory":
        path.mkdir()
    else:
        write_pairing(home, ME).chmod(0)
        if os.access(path, os.R_OK):  # root reads it anyway
            pytest.skip("running as a user that can read a mode-000 file")
    write_mirror(home, answer("granted", signed_in(ME)))
    try:
        decision = LocalScanGate().check()
    finally:
        if make == "unreadable":
            path.chmod(0o600)
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unverified_pairing")


@pytest.mark.parametrize("user_id", ["", None, 42])
def test_load_config_uploads_with_a_pairing_that_names_no_user(home, monkeypatch, user_id):
    # Why such a pairing pauses rather than reading as "not paired": the
    # config loads, so a cycle the gate let through would upload with it.
    config_path = home / lsc.PAIRING_FILENAME
    monkeypatch.setattr(h, "CONFIG_PATH", config_path)
    config_path.write_bytes(_loadable_config(user_id=user_id))
    assert h.load_config().user_id == user_id
    write_mirror(home, answer("granted", signed_in(ME)))
    rec = Recorder(monkeypatch)
    monkeypatch.setattr(h, "load_config", _REAL_LOAD_CONFIG)
    assert _cycle(LocalScanGate()) is False
    assert (rec.collected, rec.sent) == ([], [])
    # Control: with no account record the same pairing is trusted, as before
    # the record existed, and the cycle uploads with it.
    write_mirror(home, answer("granted"))
    assert _cycle(LocalScanGate()) is True
    assert rec.sent[:2] == ["helper_heartbeat", "helper_sync"]


def test_the_gate_reads_the_pairing_afresh(home):
    write_mirror(home, answer("granted", signed_in(ME)))
    gate = LocalScanGate()
    assert gate.check().reason == "not_paired"
    pairing = write_pairing(home, ME)  # paired while it runs
    assert gate.check().cycle is Cycle.COLLECT
    write_pairing(home, OTHER)  # re-paired for another user while it runs
    assert gate.check().reason == "other_account"
    pairing.unlink()  # unpaired while it runs: nothing is uploaded with the old one
    assert gate.check().reason == "not_paired"
    assert not gate.allows_upload()


@pytest.mark.parametrize(
    "values",
    [answer("declined"), answer("granted"), answer("granted", "local_mode"),
     answer("granted", "signed_out"), None],
)
def test_the_pairing_is_read_only_for_a_sign_in(home, values):
    if values is not None:
        write_mirror(home, values)
    asked: list[int] = []
    LocalScanGate(paired_user_id=lambda: asked.append(1) or ME).check()
    assert asked == []


@pytest.mark.parametrize("reader", [lambda: 1 / 0, lambda: "", lambda: "  ", lambda: 42],
                         ids=["raises", "empty", "blank", "not-a-string"])
def test_a_pairing_reader_that_cannot_say_pauses(home, reader):
    # Not "not paired": only a missing pairing file is that.
    write_mirror(home, answer("granted", signed_in(ME)))
    decision = lsc.decide(lsc.read_mirror(), reader)
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unverified_pairing")


def test_the_pairing_is_the_file_the_helper_pairs_into(home):
    # `cli_pulse_helper.CONFIG_PATH` is fixed at import, under the real HOME;
    # the name is what must agree.
    assert h.CONFIG_PATH.name == lsc.PAIRING_FILENAME
    write_pairing(home, ME)
    assert lsc.paired_user_id_from_config() == ME


def test_an_xml_plist_is_read_too(home):
    write_mirror(home, answer("declined"), fmt=plistlib.FMT_XML)
    assert lsc.decide(lsc.read_mirror()).reason == "declined"


def test_missing_container_is_no_copy(home):
    assert not (home / "Library").exists()
    read = lsc.read_mirror()
    assert read.status == "absent"
    assert lsc.decide(read).cycle is Cycle.LEGACY


def test_corrupt_plist_pauses(home):
    path = home / MIRROR
    path.parent.mkdir(parents=True)
    path.write_bytes(b"bplist00\x00\x01garbage")
    decision = lsc.decide(lsc.read_mirror())
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")


def test_non_dictionary_plist_pauses(home):
    write_mirror(home, ["cli_pulse_local_scan_consent", "granted"])  # type: ignore[arg-type]
    assert lsc.decide(lsc.read_mirror()).reason == "unreadable"


def test_a_directory_where_the_plist_should_be_pauses(home):
    (home / MIRROR).mkdir(parents=True)
    assert lsc.decide(lsc.read_mirror()).reason == "unreadable"


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads a 000 file")
def test_permission_denied_pauses(home):
    # What a helper denied access to the app's container sees: it cannot tell
    # a "Not now" from an older app, so it does not collect.
    path = write_mirror(home, answer("granted"))
    path.chmod(0o000)
    try:
        decision = lsc.decide(lsc.read_mirror())
    finally:
        path.chmod(0o600)
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")


# ── the gate ───────────────────────────────────────────────────


def test_gate_reads_the_file_at_every_check(home):
    write_pairing(home, ME)
    gate = LocalScanGate()
    assert gate.check().cycle is Cycle.LEGACY
    write_mirror(home, answer("granted"))
    assert gate.check().cycle is Cycle.COLLECT
    write_mirror(home, answer("declined"))
    assert gate.check().cycle is Cycle.PAUSED
    write_mirror(home, answer("granted", "signed_out"))
    assert gate.check().reason == "signed_out"
    write_mirror(home, answer("granted", "local_mode"))
    assert gate.allows_collection() and not gate.allows_upload()
    write_mirror(home, answer("granted", signed_in()))
    assert gate.allows_collection() and gate.allows_upload()


def test_a_stalled_read_pauses_and_is_not_read_twice():
    release = threading.Event()
    calls: list[Path] = []

    def stalled_reader(path: Path) -> MirrorRead:
        calls.append(path)
        release.wait(5.0)
        return MirrorRead("ok", consent="granted")

    gate = LocalScanGate(path=lambda: Path("/nowhere"), reader=stalled_reader, read_wait_s=0.3)
    started = time.monotonic()
    first = gate.check()
    second = gate.check()
    assert time.monotonic() - started < 2.0
    assert (first.cycle, first.reason) == (Cycle.PAUSED, "unreadable")
    assert (second.cycle, second.reason) == (Cycle.PAUSED, "unreadable")
    # The second check waited on the same read instead of opening another.
    assert len(calls) == 1

    # The read finishes while a later check is waiting on it: that check uses it.
    threading.Timer(0.05, release.set).start()
    assert gate.check().cycle is Cycle.COLLECT
    assert len(calls) == 1
    # Nothing pending now, so the next check reads afresh.
    assert gate.check().cycle is Cycle.COLLECT
    assert len(calls) == 2


def test_a_check_can_wait_less_than_the_gate_default():
    release = threading.Event()

    def stalled_reader(_path: Path) -> MirrorRead:
        release.wait(5.0)
        return MirrorRead("ok", consent="granted")

    gate = LocalScanGate(path=lambda: Path("/nowhere"), reader=stalled_reader, read_wait_s=5.0)
    started = time.monotonic()
    decision = gate.check(wait_s=0.1)
    assert time.monotonic() - started < 1.0
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")
    assert "0.1s" in decision.detail
    assert not gate.allows_collection(wait_s=0.05)
    release.set()


def test_a_read_that_finished_between_checks_is_not_used():
    # A stalled read completes after the check that started it gave up, and the
    # user answers "Not now" before the next check. The next check must not
    # act on the answer that read found.
    release = threading.Event()
    calls: list[Path] = []
    plist = {"consent": "granted"}

    def reader(path: Path) -> MirrorRead:
        calls.append(path)
        consent = plist["consent"]
        if len(calls) == 1:
            release.wait(5.0)
        return MirrorRead("ok", consent=consent)

    gate = LocalScanGate(path=lambda: Path("/nowhere"), reader=reader, read_wait_s=0.1)
    assert gate.check().reason == "unreadable"
    release.set()
    gate._pending[0].join(2.0)  # the stalled read finishes between checks
    plist["consent"] = "declined"
    decision = gate.check()
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "declined")
    assert len(calls) == 2


@pytest.mark.parametrize("ready", [lambda: False, lambda: 1 / 0])
def test_an_unreachable_container_is_not_touched(ready):
    calls: list[Path] = []

    def reader(path: Path) -> MirrorRead:
        calls.append(path)
        return MirrorRead("ok", consent="granted")

    gate = LocalScanGate(reader=reader, container_ready=ready)
    decision = gate.check()
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")
    assert calls == []


def test_a_reader_that_raises_pauses():
    def broken(_path: Path) -> MirrorRead:
        raise OSError("EPERM")

    gate = LocalScanGate(path=lambda: Path("/nowhere"), reader=broken)
    decision = gate.check()
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")
    assert "EPERM" in decision.detail


def test_gate_logs_a_change_once(home, caplog):
    caplog.set_level("INFO", logger="cli_pulse.local_scan_consent")
    gate = LocalScanGate()
    write_mirror(home, answer("declined"))
    for _ in range(3):
        gate.check()
    write_mirror(home, answer("granted"))
    for _ in range(3):
        gate.check()
    messages = [r.getMessage() for r in caplog.records if r.name == "cli_pulse.local_scan_consent"]
    assert len(messages) == 2
    assert "paused" in messages[0] and "declined" in messages[0]
    assert "allowed" in messages[1]


# ── heartbeat and sync ─────────────────────────────────────────


def _fail(name: str):
    def _called(*_a, **_k):
        raise AssertionError(f"{name} ran while the local scan was paused")
    return _called


@pytest.fixture
def nothing_may_run(monkeypatch):
    """Every read and every upload in heartbeat + sync fails the test."""
    for name in ("load_config", "collect_device_snapshot", "collect_sessions",
                 "collect_alerts", "estimate_provider_quotas", "supabase_rpc",
                 "_fetch_track_git_activity", "_ingest_commits_with_retry"):
        monkeypatch.setattr(h, name, _fail(name))
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", _fail("provider_plan_statuses"))
    monkeypatch.setattr(machine_collector, "heartbeat_metrics", _fail("heartbeat_metrics"))
    monkeypatch.setattr(sensor_bridge, "read_sensors", _fail("read_sensors"))
    monkeypatch.setattr(sc, "_fetch_claude_usage", _fail("_fetch_claude_usage"))
    monkeypatch.setattr(sc, "_fetch_codex_usage", _fail("_fetch_codex_usage"))
    monkeypatch.setattr(sc, "_fetch_gemini_usage", _fail("_fetch_gemini_usage"))


class Recorder:
    """Stands in for every collector and for `supabase_rpc`. `on_collect` runs
    while the cycle is reading, which is where a user's answer can arrive."""

    def __init__(self, monkeypatch, on_collect=None, on_rpc=None):
        self.collected: list[str] = []
        self.sent: list[str] = []
        self._on_collect = on_collect or (lambda _what: None)
        self._on_rpc = on_rpc or (lambda _name: None)
        config = types.SimpleNamespace(device_id="dev-1", helper_secret="sec", device_name="Mac")
        monkeypatch.setattr(h, "load_config", lambda: config)
        monkeypatch.setattr(h, "collect_device_snapshot", self._collect("snapshot", types.SimpleNamespace(cpu_usage=1, memory_usage=2)))
        monkeypatch.setattr(h, "collect_sessions", self._collect("sessions", []))
        monkeypatch.setattr(h, "collect_alerts", lambda *_a, **_k: [])
        monkeypatch.setattr(h, "estimate_provider_quotas", self._collect("quotas", {}))
        monkeypatch.setattr(provider_spawners, "provider_plan_statuses", dict)
        monkeypatch.setattr(machine_collector, "heartbeat_metrics", lambda **_k: None)
        monkeypatch.setattr(sensor_bridge, "read_sensors", lambda: None)
        monkeypatch.setattr(h, "supabase_rpc", self._rpc)

    def _collect(self, what, result):
        def _run(*_a, **_k):
            self.collected.append(what)
            self._on_collect(what)
            return result
        return _run

    def _rpc(self, name, _params):
        self.sent.append(name)
        self._on_rpc(name)
        if name == "get_track_git_activity":
            return False
        return {"sessions_synced": 0}


@pytest.mark.parametrize(
    "values",
    [answer("declined"), answer("granted", "signed_out"), answer("undecided", "signed_out"),
     answer("maybe"), answer("granted", signed_in(OTHER)), answer("granted", "local_mode"),
     answer("undecided", "local_mode")],
    ids=["not-now", "signed-out", "signed-out-undecided", "unrecognised", "other-account",
         "local-mode", "local-mode-undecided"],
)
def test_paused_heartbeat_and_sync_read_and_send_nothing(home, nothing_may_run, values):
    write_pairing(home, ME)
    write_mirror(home, values)
    gate = LocalScanGate()
    assert h.heartbeat(argparse.Namespace(), gate=gate) is False
    assert h.sync(argparse.Namespace(), gate=gate) is False


@pytest.mark.parametrize(
    "values",
    [None, dict(PRE_155_KEYS), answer("granted"), answer("undecided"),
     answer("granted", signed_in(ME)), answer("undecided", signed_in(ME))],
)
def test_allowed_heartbeat_and_sync_send_as_before(home, monkeypatch, values):
    write_pairing(home, ME)
    if values is not None:
        write_mirror(home, values)
    rec = Recorder(monkeypatch)
    gate = LocalScanGate()
    assert h.heartbeat(argparse.Namespace(), gate=gate) is True
    assert h.sync(argparse.Namespace(), gate=gate) is True
    assert rec.sent == ["helper_heartbeat", "helper_sync"]


LATE_ANSWERS = pytest.mark.parametrize(
    "late_answer",
    [answer("declined", signed_in()), answer("granted", "signed_out"),
     answer("granted", signed_in(OTHER)), answer("granted", "local_mode")],
    ids=["not-now", "sign-out", "account-switch", "local-mode"],
)


@LATE_ANSWERS
def test_an_answer_given_mid_heartbeat_drops_it(home, monkeypatch, late_answer):
    write_pairing(home, ME)
    write_mirror(home, answer("granted", signed_in()))
    rec = Recorder(monkeypatch, on_collect=lambda _what: write_mirror(home, late_answer))
    assert h.heartbeat(argparse.Namespace(), gate=LocalScanGate()) is False
    assert rec.collected  # it was already reading
    assert rec.sent == []


@LATE_ANSWERS
def test_an_answer_given_mid_sync_drops_it(home, monkeypatch, late_answer):
    write_pairing(home, ME)
    write_mirror(home, answer("granted", signed_in()))

    def on_collect(what):
        if what == "quotas":  # the last read before the upload
            write_mirror(home, late_answer)

    rec = Recorder(monkeypatch, on_collect=on_collect)
    assert h.sync(argparse.Namespace(), gate=LocalScanGate()) is False
    assert "quotas" in rec.collected
    assert rec.sent == []


def test_without_a_gate_heartbeat_and_sync_are_unchanged(home, monkeypatch):
    # Callers that pass no gate (existing tests) keep the old behaviour; the
    # helper's own entry points are checked below to pass one.
    write_mirror(home, answer("declined"))
    rec = Recorder(monkeypatch)
    h.heartbeat(argparse.Namespace())
    h.sync(argparse.Namespace())
    assert rec.sent == ["helper_heartbeat", "helper_sync"]


# ── the daemon cycle ───────────────────────────────────────────


def _cycle(gate, git=None):
    return h._collection_cycle(
        argparse.Namespace(), gate=gate, git=git or h._GitScanState(), env_force_git=False,
    )


@pytest.mark.parametrize(
    "values",
    [answer("declined"), answer("granted", "signed_out"), answer("granted", signed_in(OTHER)),
     answer("granted", "local_mode")],
    ids=["not-now", "signed-out", "other-account", "local-mode"],
)
def test_paused_cycle_reads_and_sends_nothing(home, nothing_may_run, values):
    # Local mode included: every step of the cycle uploads.
    write_pairing(home, ME)
    write_mirror(home, values)
    assert _cycle(LocalScanGate()) is False


def test_allowed_cycle_runs_as_before(home, monkeypatch):
    write_mirror(home, answer("granted"))
    rec = Recorder(monkeypatch)
    assert _cycle(LocalScanGate()) is True
    assert rec.sent == ["helper_heartbeat", "helper_sync", "get_track_git_activity"]


def test_legacy_cycle_runs_as_before(home, monkeypatch):
    write_mirror(home, dict(PRE_155_KEYS))
    rec = Recorder(monkeypatch)
    assert _cycle(LocalScanGate()) is True
    assert rec.sent == ["helper_heartbeat", "helper_sync", "get_track_git_activity"]


def test_a_not_now_after_sync_skips_the_git_lookup(home, monkeypatch):
    write_mirror(home, answer("granted"))

    def on_rpc(name):
        if name == "helper_sync":
            write_mirror(home, answer("declined"))

    rec = Recorder(monkeypatch, on_rpc=on_rpc)
    assert _cycle(LocalScanGate()) is False
    assert rec.sent == ["helper_heartbeat", "helper_sync"]


class _Commit:
    def to_dict(self):
        return {"sha": "abc"}


def _git_cycle(home, monkeypatch, *, not_now_during_scan: bool):
    write_mirror(home, answer("granted"))
    Recorder(monkeypatch)
    monkeypatch.setattr(h, "project_paths_from_sessions", lambda _s: [Path("/repo")])

    class Scanner:
        def collect(self, _paths):
            if not_now_during_scan:
                write_mirror(home, answer("declined"))
            return [_Commit()]

    ingested: list[list[dict]] = []
    monkeypatch.setattr(h, "_ingest_commits_with_retry",
                        lambda _config, payloads, batch_size: ingested.append(payloads))
    git = h._GitScanState(scanner=Scanner())
    result = h._collection_cycle(argparse.Namespace(), gate=LocalScanGate(), git=git, env_force_git=True)
    return result, git, ingested


def test_commits_read_before_a_not_now_are_not_submitted(home, monkeypatch):
    result, git, ingested = _git_cycle(home, monkeypatch, not_now_during_scan=True)
    assert result is False
    assert ingested == []
    # The cursor did not move, so an allowed cycle picks the commits up later.
    assert git.last_projects == frozenset()
    assert git.last_scan_at == 0.0


def test_commits_are_submitted_when_allowed(home, monkeypatch):
    result, git, ingested = _git_cycle(home, monkeypatch, not_now_during_scan=False)
    assert result is True
    assert ingested == [[{"sha": "abc"}]]
    assert git.last_projects == frozenset({"/repo"})


# ── what the collector does mid-cycle: token refreshes, result writes ──


SNAPSHOT = {"tiers": [{"name": "5h Window", "quota": 100, "remaining": 40, "reset_time": None}]}


def _written(home: Path) -> list[Path]:
    return sorted(p for p in home.rglob("claude_*.json"))


@pytest.fixture
def reset_cycle_gate():
    yield
    sc.set_cycle_gate(None)


@pytest.mark.parametrize("gate", [lambda: False, lambda: 1 / 0])
def test_a_paused_cycle_writes_no_claude_snapshot(home, reset_cycle_gate, gate):
    sc.set_cycle_gate(gate)
    sc._write_claude_snapshot(SNAPSHOT, "max", "oauth")
    sc._write_claude_session_key("sk-ant-sid-x", "chrome")
    assert _written(home) == []


def test_the_daemon_gate_stops_the_snapshot_write(home, reset_cycle_gate):
    write_mirror(home, answer("declined"))
    sc.set_cycle_gate(LocalScanGate().allows_collection)
    sc._write_claude_snapshot(SNAPSHOT, "max", "oauth")
    assert _written(home) == []


def test_an_allowed_cycle_writes_the_snapshot_as_before(home, reset_cycle_gate):
    write_mirror(home, answer("granted"))
    sc.set_cycle_gate(LocalScanGate().allows_collection)
    sc._write_claude_snapshot(SNAPSHOT, "max", "oauth")
    assert [p.name for p in _written(home)] == ["claude_snapshot.json", "claude_snapshot.json"]


class _TokenResponse:
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


def _gemini_creds(home: Path) -> Path:
    path = home / ".gemini" / "oauth_creds.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('{"access_token": "old", "refresh_token": "rt", "client_id": "cid"}')
    return path


@pytest.mark.parametrize("paused", [True, False], ids=["paused", "allowed"])
def test_a_paused_cycle_refreshes_no_token_and_rewrites_no_credential(home, monkeypatch, reset_cycle_gate, paused):
    write_mirror(home, answer("declined" if paused else "granted"))
    sc.set_cycle_gate(LocalScanGate().allows_collection)
    requests: list[str] = []

    def fake_urlopen(req, timeout=None):
        requests.append(req.full_url)
        if "googleapis" in req.full_url:
            return _TokenResponse(b'{"access_token": "new", "expires_in": 3600}')
        return _TokenResponse(b'{"access_token": "sk-ant-oat-new"}')

    monkeypatch.setattr(sc.urllib.request, "urlopen", fake_urlopen)
    creds = _gemini_creds(home)
    claude = sc._refresh_claude_token("rt")
    gemini = sc._refresh_gemini_token(creds)
    if paused:
        assert (claude, gemini, requests) == (None, None, [])
        assert '"old"' in creds.read_text()
    else:
        assert (claude, gemini) == ("sk-ant-oat-new", "new")
        assert len(requests) == 2
        assert '"new"' in creds.read_text()


class _Ran:
    returncode = 1
    stdout = ""


@pytest.mark.parametrize("paused", [True, False], ids=["paused", "allowed"])
def test_a_paused_cycle_runs_no_claude_cli(home, monkeypatch, reset_cycle_gate, paused):
    # `claude /usage` can refresh Claude's OAuth token while it runs, which
    # rewrites its Keychain item or ~/.claude/.credentials.json.
    write_mirror(home, answer("declined" if paused else "granted"))
    sc.set_cycle_gate(LocalScanGate().allows_collection)
    monkeypatch.setattr("shutil.which", lambda name: f"/opt/fake/{name}")
    runs: list[list[str]] = []

    def fake_run(cmd, **_kwargs):
        runs.append(cmd)
        return _Ran()

    monkeypatch.setattr(sc.subprocess, "run", fake_run)
    assert sc._fetch_claude_cli("max") is None
    if paused:
        assert runs == []
    else:
        assert [cmd[0] for cmd in runs] == ["/opt/fake/claude"]


# ── hello: the credential file behind provider_plan_status ─────


def _hello(local_scan_allowed) -> dict:
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
    return server._handle_method("hello", {})


@pytest.mark.parametrize("allowed", [lambda: False, lambda: 1 / 0])
def test_a_paused_hello_reads_no_credential_file(monkeypatch, allowed):
    # provider_plan_statuses() opens ~/.codex/auth.json.
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", _fail("provider_plan_statuses"))
    reply = _hello(allowed)
    # Absent reads as "no warning" in the app (LocalSessionControlClient).
    assert "provider_plan_status" not in reply
    assert reply["implementation"] == "python-pkg"  # the rest of hello is unchanged


@pytest.mark.parametrize(
    ("values", "reads"),
    [
        (answer("declined"), False),
        (answer("granted"), True),
        (None, True),  # no copy from a pre-1.55 app: as before
        # Local mode after a yes: hello answers only the app on this Mac.
        (answer("granted", "local_mode"), True),
        (answer("undecided", "local_mode"), False),
        (answer("granted", "signed_out"), False),
        (answer("granted", signed_in(OTHER)), False),
        (answer("granted", signed_in(ME)), True),
    ],
)
def test_hello_follows_the_apps_answer(home, monkeypatch, values, reads):
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", lambda: {"codex": "off_plan"})
    write_pairing(home, ME)
    if values is not None:
        write_mirror(home, values)
    reply = _hello(LocalScanGate().allows_collection)
    if reads:
        assert reply["provider_plan_status"] == {"codex": "off_plan"}
    else:
        assert "provider_plan_status" not in reply


def test_without_a_gate_hello_is_unchanged(monkeypatch):
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", lambda: {"codex": "on_plan"})
    assert _hello(None)["provider_plan_status"] == {"codex": "on_plan"}


# ── wiring: the entry points that upload are the gated ones ────


def _capture_gate(monkeypatch, *names):
    seen: dict[str, object] = {}
    for name in names:
        def _record(_args, gate=None, _name=name):
            seen[_name] = gate
            return False
        monkeypatch.setattr(h, name, _record)
    return seen


@pytest.mark.parametrize(("argv", "names"), [
    (["heartbeat"], ("heartbeat",)),
    (["sync"], ("sync",)),
    (["run-demo", "--cycles", "1", "--interval", "0"], ("heartbeat", "sync")),
])
def test_subcommands_that_upload_pass_a_gate(monkeypatch, argv, names):
    seen = _capture_gate(monkeypatch, *names)
    monkeypatch.setattr(sys, "argv", ["cli_pulse_helper", *argv])
    monkeypatch.setattr(h.time, "sleep", lambda _s: None)
    h.main()
    assert set(seen) == set(names)
    assert all(isinstance(g, LocalScanGate) for g in seen.values())


def _run_one_daemon_cycle(monkeypatch, body) -> None:
    """Run `daemon()` for exactly one cycle, with `body(kwargs)` in place of the
    cycle. Whatever `body` raises is raised here: the daemon itself would log
    it and sleep until the next cycle, so a failing check would hang the test
    instead of failing it."""
    box: dict = {}

    def one_cycle(_args, **kwargs):
        try:
            body(kwargs)
        except BaseException as exc:  # noqa: BLE001 — re-raised below
            box["exc"] = exc
        raise KeyboardInterrupt  # ends the daemon after its first cycle

    monkeypatch.setattr(h, "_collection_cycle", one_cycle)
    h.daemon(argparse.Namespace(interval=60))
    if "exc" in box:
        raise box["exc"]


def test_daemon_runs_its_cycles_through_the_gate(home, monkeypatch):
    import signal

    write_mirror(home, answer("declined"))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    # Startup rotation "stalled": the daemon skips its socket; nothing binds.
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    seen: dict = {}

    def one_cycle(kwargs):
        seen.update(kwargs)
        seen["cycle_gate"] = sc._cycle_gate
        seen["decision"] = kwargs["gate"].check()

    _run_one_daemon_cycle(monkeypatch, one_cycle)

    gate = seen["gate"]
    assert isinstance(gate, LocalScanGate)
    assert seen["decision"].reason == "declined"  # it reads the app's plist
    assert seen["cycle_gate"] == gate.allows_collection
    assert sc._cycle_gate is None  # reset on the way out


def test_the_daemon_gate_waits_for_a_stuck_startup_rotation(home, monkeypatch):
    # The startup token rotation is still inside its container access (a TCC
    # consult under launchd). The daemon's gate must not open a second access
    # to that container: it answers "unreadable" without reading the plist,
    # which says "granted", so a gate that read it would collect.
    import signal

    mirror = write_mirror(home, answer("granted"))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: None)
    release = threading.Event()
    stuck = threading.Thread(target=release.wait, args=(5.0,), name="rotate-token", daemon=True)
    stuck.start()
    monkeypatch.setattr(h, "_container_rotation_worker", stuck)
    opened: list[str] = []
    real_load = lsc.plistlib.load

    def spy_load(fh, *a, **k):
        if Path(getattr(fh, "name", "")) == mirror:
            opened.append(fh.name)
        return real_load(fh, *a, **k)

    monkeypatch.setattr(lsc.plistlib, "load", spy_load)
    seen: dict = {}

    def one_cycle(kwargs):
        seen["decision"] = kwargs["gate"].check()

    try:
        _run_one_daemon_cycle(monkeypatch, one_cycle)
    finally:
        release.set()
        stuck.join(2.0)

    decision = seen["decision"]
    assert (decision.cycle, decision.reason) == (Cycle.PAUSED, "unreadable")
    assert "not reachable" in decision.detail
    assert opened == []


def test_the_daemon_wires_its_gate_into_hello(home, monkeypatch):
    import signal

    import local_session_server

    write_mirror(home, answer("declined"))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    # The rotation completes, so the daemon builds and starts its UDS server.
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: "T")
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    built: dict = {}

    class FakeServer:
        def __init__(self, **kwargs):
            built.update(kwargs)

        def start(self):
            pass

        def stop(self):
            pass

    monkeypatch.setattr(local_session_server, "LocalSessionServer", FakeServer)
    waits: list = []

    class RecordingGate(LocalScanGate):
        def allows_collection(self, *, wait_s=None):
            waits.append(wait_s)
            return super().allows_collection(wait_s=wait_s)

    monkeypatch.setattr(h, "LocalScanGate", RecordingGate)
    seen: dict = {}

    def one_cycle(kwargs):
        allowed = built["local_scan_allowed"]
        seen["declined"] = allowed()
        write_mirror(home, answer("granted"))
        seen["granted"] = allowed()
        seen["same_gate"] = isinstance(kwargs["gate"], RecordingGate)

    _run_one_daemon_cycle(monkeypatch, one_cycle)
    assert seen == {"declined": False, "granted": True, "same_gate": True}
    # hello waits well inside the app's 5 s request timeout, not READ_WAIT_S.
    assert waits == [h._HELLO_LOCAL_SCAN_WAIT_S] * 2
    assert 0 < h._HELLO_LOCAL_SCAN_WAIT_S < 5


def _fail_config():
    raise h.ConfigError("not paired (test)")


def test_container_is_unreachable_while_the_startup_rotation_is_stuck(monkeypatch):
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    assert h._container_reachable()
    release = threading.Event()
    assert h._rotate_token_best_effort(lambda: release.wait(5.0) and "T", timeout=0.05) is None
    assert not h._container_reachable()
    release.set()
    h._container_rotation_worker.join(2.0)
    assert h._container_reachable()


# ── every account × every answer ───────────────────────────────
#
# What the #626 contract says each combination does, written out here from the
# contract rather than taken from `decide`:
#   "upload"  - read this Mac and send heartbeat and sync;
#   "local"   - answer the app on this Mac (`hello`), send nothing;
#   "nothing" - read nothing, send nothing.
# Each combination is checked at the gate (through the file and, on a Mac,
# through cfprefsd), in a daemon cycle that loads the pairing from disk the way
# the helper does, and at `hello`.

# id: (the value under `cli_pulse_app_account`, None for no record;
#      the pairing on disk: "me" (paired for ME), "no-user" (a config
#      `load_config` accepts, with an empty user id) or None (not paired))
ACCOUNT_STATES = {
    "no-record": (None, "me"),
    "signed-in-as-the-pairing": (signed_in(ME), "me"),
    "signed-in-as-the-pairing-upper-case": (signed_in(ME.upper()), "me"),
    "signed-in-as-another-account": (signed_in(OTHER), "me"),
    "signed-in-not-paired": (signed_in(ME), None),
    "signed-in-pairing-names-no-user": (signed_in(ME), "no-user"),
    "local-mode": ("local_mode", "me"),
    "local-mode-not-paired": ("local_mode", None),
    "signed-out": ("signed_out", "me"),
    "signed-out-not-paired": ("signed_out", None),
    "signed-in-with-no-user-id": ("signed_in:", "me"),
    "unknown-record": ("guest", "me"),
    "record-not-a-string": (True, "me"),
}
ANSWERS = {
    "no-answer": None,
    "undecided": "undecided",
    "granted": "granted",
    "declined": "declined",
    "unrecognised": "maybe",
}
MATRIX = pytest.mark.parametrize(
    ("state", "consent"),
    [
        pytest.param(state, consent, id=f"{state_id}-{consent_id}")
        for state_id, state in ACCOUNT_STATES.items()
        for consent_id, consent in ANSWERS.items()
    ],
)


def contract(account, pairing, consent) -> str:
    if account is None:
        # No record: the pairing is trusted, as before the record existed.
        if consent is None:
            return "upload"  # no copy at all: an app older than 1.55
        return "upload" if consent in ("granted", "undecided") else "nothing"
    if account == "local_mode":
        return "local" if consent == "granted" else "nothing"
    prefix = "signed_in:"
    user = account[len(prefix):] if isinstance(account, str) and account.startswith(prefix) else ""
    if not user:
        return "nothing"  # signed out, or a record this helper does not know
    if consent not in ("granted", "undecided"):
        return "nothing"
    if pairing is None:
        return "local"
    return "upload" if pairing == "me" and user.lower() == ME else "nothing"


def _set_up(home, monkeypatch, state, consent, write=None) -> str:
    account, pairing = state
    config_path = home / lsc.PAIRING_FILENAME
    monkeypatch.setattr(h, "CONFIG_PATH", config_path)
    if pairing == "me":
        config_path.write_bytes(_loadable_config())
    elif pairing == "no-user":
        config_path.write_bytes(_loadable_config(user_id=""))
    values = answer(consent, account)
    if write is None:
        write_mirror(home, values)
    else:
        write(values)
    return contract(account, pairing, consent)


def test_the_matrix_covers_every_outcome():
    outcomes = {contract(*ACCOUNT_STATES[s][:2], c) for s in ACCOUNT_STATES for c in ANSWERS.values()}
    assert outcomes == {"upload", "local", "nothing"}


@MATRIX
def test_every_account_and_answer_at_the_gate(home, monkeypatch, app_group_copy, state, consent):
    expected = _set_up(home, monkeypatch, state, consent, app_group_copy.write)
    decision = LocalScanGate().check()
    assert decision.allows_upload is (expected == "upload"), decision
    assert decision.allows_collection is (expected != "nothing"), decision


@MATRIX
def test_every_account_and_answer_in_the_daemon_cycle(home, monkeypatch, state, consent):
    expected = _set_up(home, monkeypatch, state, consent)
    rec = Recorder(monkeypatch)
    # The pairing as the helper loads it: a pairing with no usable user id
    # loads, and a missing one raises, so only the gate stands between them
    # and an upload.
    monkeypatch.setattr(h, "load_config", _REAL_LOAD_CONFIG)
    ran = _cycle(LocalScanGate())
    if expected == "upload":
        assert ran is True
        assert rec.sent == ["helper_heartbeat", "helper_sync", "get_track_git_activity"]
    else:
        assert ran is False
        assert (rec.collected, rec.sent) == ([], [])


@MATRIX
def test_every_account_and_answer_at_hello(home, monkeypatch, state, consent):
    expected = _set_up(home, monkeypatch, state, consent)
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", lambda: {"codex": "off_plan"})
    reply = _hello(LocalScanGate().allows_collection)
    if expected == "nothing":
        assert "provider_plan_status" not in reply
    else:
        assert reply["provider_plan_status"] == {"codex": "off_plan"}
