"""The Companion CLI honours the Mac app's local-scan answer.

The app (1.55+) copies its answer into its app-group defaults, a cfprefsd plist
in the group container. These tests write that plist where the app does, under
a throwaway HOME, and check what the helper then reads and sends:

  * the decision for every answer, sign-in record, and the file being absent,
    from an older app, or unreadable;
  * that the gate reads the file on every check, does not stack a second read on
    a stalled one, and does not touch a container the startup rotation is still
    stuck in;
  * that a paused heartbeat, sync or daemon cycle reads nothing (every collector
    fails the test if called) and sends nothing;
  * that an answer given while a cycle runs drops what the cycle collected,
    before each upload, the git lookup, the commit submit, the Claude snapshot
    write, and any Claude or Gemini token refresh (the Gemini one rewrites its
    credential file);
  * that the daemon and the `heartbeat` / `sync` / `run-demo` subcommands are
    the ones wired to the gate.
"""
from __future__ import annotations

import argparse
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


def answer(consent=None, signed_out=None, **extra) -> dict:
    values = dict(PRE_155_KEYS)
    if consent is not None:
        values["cli_pulse_local_scan_consent"] = consent
    if signed_out is not None:
        values["cli_pulse_app_signed_out"] = signed_out
    values.update(extra)
    return values


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
        # The answers.
        (answer("declined"), Cycle.PAUSED, "declined"),
        (answer("granted"), Cycle.COLLECT, "granted"),
        (answer("undecided"), Cycle.COLLECT, "undecided"),
        # The sign-in record.
        (answer("declined", signed_out=False), Cycle.PAUSED, "declined"),
        (answer("granted", signed_out=False), Cycle.COLLECT, "granted"),
        (answer("undecided", signed_out=False), Cycle.COLLECT, "undecided"),
        (answer("granted", signed_out=True), Cycle.PAUSED, "signed_out"),
        (answer("undecided", signed_out=True), Cycle.PAUSED, "signed_out"),
        (answer("declined", signed_out=True), Cycle.PAUSED, "signed_out"),
        # Only a 1.55+ app writes the sign-in record, so it counts on its own.
        (answer(signed_out=True), Cycle.PAUSED, "signed_out"),
        (answer(signed_out=False), Cycle.LEGACY, "no_copy"),
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
def test_decision_for_every_answer(home, values, cycle, reason):
    if values is not None:
        write_mirror(home, values)
    decision = lsc.decide(lsc.read_mirror())
    assert (decision.cycle, decision.reason) == (cycle, reason)
    assert decision.allows_collection is (cycle is not Cycle.PAUSED)


@pytest.mark.parametrize(
    ("stored", "signed_out"),
    [(True, True), (1, True), ("YES", True), ("true", True),
     (False, False), (0, False), ("NO", False), ("", False)],
)
def test_sign_in_record_reads_like_userdefaults_bool(home, stored, signed_out):
    write_mirror(home, answer("granted", signed_out=stored))
    assert lsc.read_mirror().signed_out is signed_out
    assert lsc.decide(lsc.read_mirror()).allows_collection is (not signed_out)


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
    gate = LocalScanGate()
    assert gate.check().cycle is Cycle.LEGACY
    write_mirror(home, answer("granted"))
    assert gate.check().cycle is Cycle.COLLECT
    write_mirror(home, answer("declined"))
    assert gate.check().cycle is Cycle.PAUSED
    write_mirror(home, answer("granted", signed_out=True))
    assert gate.check().reason == "signed_out"
    write_mirror(home, answer("granted", signed_out=False))
    assert gate.allows_collection()


def test_a_stalled_read_pauses_and_is_not_read_twice():
    release = threading.Event()
    calls: list[Path] = []

    def stalled_reader(path: Path) -> MirrorRead:
        calls.append(path)
        release.wait(5.0)
        return MirrorRead("ok", consent="granted")

    gate = LocalScanGate(path=lambda: Path("/nowhere"), reader=stalled_reader, read_wait_s=0.1)
    started = time.monotonic()
    first = gate.check()
    second = gate.check()
    assert time.monotonic() - started < 2.0
    assert (first.cycle, first.reason) == (Cycle.PAUSED, "unreadable")
    assert (second.cycle, second.reason) == (Cycle.PAUSED, "unreadable")
    # The second check waited on the same read instead of opening another.
    assert len(calls) == 1

    release.set()
    assert gate.check().cycle is Cycle.COLLECT  # the stalled read's own answer
    assert len(calls) == 1
    assert gate.check().cycle is Cycle.COLLECT
    assert len(calls) == 2  # and only then a fresh read


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
    [answer("declined"), answer("granted", signed_out=True), answer("undecided", signed_out=True),
     answer("maybe")],
)
def test_paused_heartbeat_and_sync_read_and_send_nothing(home, nothing_may_run, values):
    write_mirror(home, values)
    gate = LocalScanGate()
    assert h.heartbeat(argparse.Namespace(), gate=gate) is False
    assert h.sync(argparse.Namespace(), gate=gate) is False


@pytest.mark.parametrize(
    "values",
    [None, dict(PRE_155_KEYS), answer("granted"), answer("undecided"), answer("granted", signed_out=False)],
)
def test_allowed_heartbeat_and_sync_send_as_before(home, monkeypatch, values):
    if values is not None:
        write_mirror(home, values)
    rec = Recorder(monkeypatch)
    gate = LocalScanGate()
    assert h.heartbeat(argparse.Namespace(), gate=gate) is True
    assert h.sync(argparse.Namespace(), gate=gate) is True
    assert rec.sent == ["helper_heartbeat", "helper_sync"]


@pytest.mark.parametrize(
    "late_answer",
    [answer("declined"), answer("granted", signed_out=True)],
    ids=["not-now", "sign-out"],
)
def test_an_answer_given_mid_heartbeat_drops_it(home, monkeypatch, late_answer):
    write_mirror(home, answer("granted"))
    rec = Recorder(monkeypatch, on_collect=lambda _what: write_mirror(home, late_answer))
    assert h.heartbeat(argparse.Namespace(), gate=LocalScanGate()) is False
    assert rec.collected  # it was already reading
    assert rec.sent == []


@pytest.mark.parametrize(
    "late_answer",
    [answer("declined"), answer("granted", signed_out=True)],
    ids=["not-now", "sign-out"],
)
def test_an_answer_given_mid_sync_drops_it(home, monkeypatch, late_answer):
    write_mirror(home, answer("granted"))

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


def test_paused_cycle_reads_and_sends_nothing(home, nothing_may_run):
    write_mirror(home, answer("declined"))
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


def test_daemon_runs_its_cycles_through_the_gate(home, monkeypatch):
    import signal

    write_mirror(home, answer("declined"))
    monkeypatch.setattr(signal, "signal", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "load_config", _fail_config)
    # Startup rotation "stalled": the daemon skips its socket; nothing binds.
    monkeypatch.setattr(h, "_rotate_token_best_effort", lambda *_a, **_k: None)
    monkeypatch.setattr(h, "_container_rotation_worker", None)
    seen: dict = {}

    def one_cycle(args, **kwargs):
        seen.update(kwargs)
        seen["cycle_gate"] = sc._cycle_gate
        seen["decision"] = kwargs["gate"].check()
        raise KeyboardInterrupt  # ends the daemon after its first cycle

    monkeypatch.setattr(h, "_collection_cycle", one_cycle)
    h.daemon(argparse.Namespace(interval=60))

    gate = seen["gate"]
    assert isinstance(gate, LocalScanGate)
    assert seen["decision"].reason == "declined"  # it reads the app's plist
    assert seen["cycle_gate"] == gate.allows_collection
    assert sc._cycle_gate is None  # reset on the way out


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
