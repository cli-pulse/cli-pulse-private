"""The Companion sees what ANOTHER process wrote with `UserDefaults` at once.

The app writes its answers with `UserDefaults(suiteName: "group.yyh.CLI-Pulse")`
and never synchronizes. cfprefsd holds the value and writes the plist file
later, so the file can lag by seconds; `app_group_prefs` therefore asks
cfprefsd, naming the domain by its plist's absolute path. That this sees the
app's write depends on two things the tests in `test_privacy_switches.py` do
not reach, because there the writer is the reading process itself (which reads
back its own cache) and names the domain by path, as the reader does:

  * a write made in another process is served to this one without delay,
    including to a reader that has already read the domain (the daemon is
    long-lived and reads before the app has written anything);
  * a domain written by suite NAME (what `UserDefaults(suiteName:)` does) is
    the domain the reader asks for by PATH.

So here the writer is a separate process, a few lines of Swift that write
exactly as the app does, compiled once for the session. The suite is a
throwaway one in this user's `~/Library/Preferences` (where an unsandboxed
process without the app-group entitlement keeps it), removed afterwards. The
app's own suite lives in the group container; cfprefsd resolves that name to
a path the same way.

Measured by hand on macOS 27 (2026-10-01) with the same writer: 245 writes, read
straight after each one returned; the reader here saw every one (0 stale), with
or without `CFPreferencesAppSynchronize` first, while the plist file was stale
242 times and caught up 0 to 6.3 s later. With the plist file read in place
of cfprefsd, both tests below fail: the file still held the previous write.

macOS only: Helper CI runs this file in its macOS job, where a skip fails.
"""
from __future__ import annotations

import os
import pwd
import shutil
import subprocess
import sys
import threading
import uuid
from pathlib import Path

import pytest
from conftest import darwin_only

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import app_group_prefs  # noqa: E402
import local_scan_consent as lsc  # noqa: E402
from local_scan_consent import Cycle  # noqa: E402

pytestmark = darwin_only

# Writes as the app writes: `UserDefaults(suiteName:)`, `set`, and never
# `synchronize()`. One line on stdin per write; "ok" once `set` has returned.
WRITER_SWIFT = r"""
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
guard let defaults = UserDefaults(suiteName: CommandLine.arguments[1]) else { exit(2) }
print("ready")
while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
    if parts.count == 3 && parts[0] == "SET" {
        defaults.set(parts[2], forKey: parts[1])
    } else if parts.count == 2 && parts[0] == "DEL" {
        defaults.removeObject(forKey: parts[1])
    } else {
        exit(0)
    }
    print("ok")
}
"""


@pytest.fixture(scope="session")
def writer_binary(tmp_path_factory) -> Path:
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        pytest.skip("swiftc is not installed")
    work = tmp_path_factory.mktemp("userdefaults-writer")
    source = work / "writer.swift"
    source.write_text(WRITER_SWIFT)
    binary = work / "writer"
    subprocess.run([swiftc, str(source), "-o", str(binary)], check=True, timeout=240,
                   capture_output=True)
    return binary


# How long the writer may take to answer one line. It answers in milliseconds;
# this only turns a writer that hangs into a failure instead of a stuck job.
WRITER_REPLY_S = 30.0


class UserDefaultsWriter:
    """Another process writing a throwaway suite with `UserDefaults`."""

    def __init__(self, binary: Path) -> None:
        self.suite = f"com.clipulse.helper-tests.cfprefs-{uuid.uuid4().hex[:12]}"
        # cfprefsd keeps an unsandboxed process's suite in the user's own
        # Preferences folder, whatever HOME says.
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        self.path = home / "Library" / "Preferences" / f"{self.suite}.plist"
        self._proc = subprocess.Popen([str(binary), self.suite], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, text=True, bufsize=1)
        assert self._reply("start") == "ready"

    def _reply(self, what: str) -> str:
        box: list[str] = []
        reader = threading.Thread(target=lambda: box.append(self._proc.stdout.readline()),
                                  daemon=True)
        reader.start()
        reader.join(WRITER_REPLY_S)
        if reader.is_alive():
            self._proc.kill()  # ends the readline with EOF
            pytest.fail(f"the UserDefaults writer did not answer {what!r} within {WRITER_REPLY_S:g}s")
        return box[0].strip() if box else ""

    def _send(self, line: str) -> None:
        self._proc.stdin.write(line + "\n")
        self._proc.stdin.flush()
        assert self._reply(line) == "ok", line

    def set(self, key: str, value: str) -> None:
        self._send(f"SET {key} {value}")

    def remove(self, key: str) -> None:
        self._send(f"DEL {key}")

    def close(self) -> None:
        try:
            self._proc.stdin.write("QUIT\n")
            self._proc.stdin.flush()
            self._proc.wait(10)
        finally:
            if self._proc.poll() is None:
                self._proc.kill()
            subprocess.run(["defaults", "delete", self.suite], capture_output=True, timeout=30)
            self.path.unlink(missing_ok=True)


@pytest.fixture
def other_process(writer_binary, monkeypatch):
    monkeypatch.setattr(app_group_prefs, "ENABLED", True)  # conftest turns it off
    writer = UserDefaultsWriter(writer_binary)
    try:
        yield writer
    finally:
        writer.close()


def test_a_write_from_another_process_is_read_at_once(other_process):
    key = "cli_pulse_local_scan_consent"
    path = other_process.path
    # This process reads the domain before anything is written, as the daemon
    # does when it starts before the app.
    assert app_group_prefs.copy_values(path, [key]) is None
    for i in range(25):
        value = f"v{i}-{uuid.uuid4().hex[:6]}"
        other_process.set(key, value)
        # No retry and no wait: the next read must already see it.
        assert app_group_prefs.copy_values(path, [key]) == {key: value}, i
    other_process.remove(key)
    assert app_group_prefs.copy_values(path, [key]) is None


def test_a_not_now_or_a_sign_out_from_another_process_decides_the_next_check(other_process):
    path = other_process.path
    other_process.set(lsc.APP_ACCOUNT_KEY, "local_mode")
    steps = [
        (lsc.CONSENT_KEY, "granted", Cycle.LOCAL, "local_mode"),
        (lsc.CONSENT_KEY, "declined", Cycle.PAUSED, "declined"),
        (lsc.CONSENT_KEY, "granted", Cycle.LOCAL, "local_mode"),
        (lsc.APP_ACCOUNT_KEY, "signed_out", Cycle.PAUSED, "signed_out"),
        (lsc.APP_ACCOUNT_KEY, "local_mode", Cycle.LOCAL, "local_mode"),
    ]
    for key, value, cycle, reason in steps:
        other_process.set(key, value)
        read = lsc.read_mirror(path)
        assert read.source == "cfprefsd", (key, value)
        decision = lsc.decide(read)
        assert (decision.cycle, decision.reason) == (cycle, reason), (key, value)
