"""Settings › Privacy's Claude keychain switches, as the Companion CLI obeys them.

The Mac app offers two switches:

  * "Strict privacy mode": CLI Pulse reads no other app's secrets on its own
    (Claude Code's and Zed's keychain items, browsers' cookies and their "Safe
    Storage" keychain items), and sends no anonymous statistics;
  * "Skip Claude Code keychain access": stops CLI Pulse reading that item.

Until 1.55 they were saved only in the app's own defaults, so this helper never
saw them and went on reading the item ("Claude Code-credentials") on its own:
every cycle for Claude's quota (`system_collector._fetch_claude_usage`), and at
each managed Claude session start as a fallback token source
(`claude_oauth.read_claude_oauth`), where a token read there could also be
refreshed and written into `~/.claude/.credentials.json`.

From 1.55 the app copies both into its app group (`HelperPrivacyInputs.swift`),
next to the local-scan answer, and this module decides from that copy whether
the item may be read. It is read the way the answer is read
(`LocalScanGate.read`: cfprefsd first, a bounded wait, nothing while the
container is not reachable), afresh at every decision, so a switch turned on
stops the next read.

WHAT EACH COPY MEANS HERE (`decide_claude_keychain`)
----------------------------------------------------
  * No copy (neither key): an app older than 1.55, which never writes one. The
    item is read as before, as the answer's "no copy" collects as before. The
    LoginItem helper differs on purpose (it skips until its app writes a copy),
    for the same reason as for the answer: it ships inside an app that always
    writes one, and this helper may be paired with an app that never will.
  * Strict privacy mode on: skipped.
  * "Skip Claude Code keychain access" on: skipped.
  * Both off: read.
  * A copy that cannot be read: skipped. Unlike "no copy", it may hold a yes.

Skipped means only that item. The file `~/.claude/.credentials.json` and
`claude /usage` are not what either switch names, and the app does not stop them
either. This helper sends no anonymous statistics at all.

STRICT PRIVACY MODE AND YOUR BROWSERS (`decide_browser_cookies`)
----------------------------------------------------------------
Strict privacy mode means CLI Pulse reads no other app's secrets on its own. So
from 1.55 it also stops this helper's claude.ai fallback
(`system_collector._resolve_claude_session_key`): opening the Claude desktop
app's and Chromium browsers' cookie stores (Chrome, Edge, Brave, Chromium, Arc)
and reading each one's "Safe Storage" keychain item to decrypt the claude.ai
`sessionKey`. The same copy, read the same way, decides it:

  * No copy (neither key): an app older than 1.55. Read as before.
  * Strict privacy mode on: skipped: no cookie store opened, no keychain item
    read, and so no claude.ai cookie written for the app either. The one this
    helper copied for the app in an earlier cycle (`claude_session.json`) is
    removed at the start of each cycle
    (`system_collector.forget_claude_session_key_under_strict_privacy_mode`),
    and the app ignores that file in Strict privacy mode.
  * Strict privacy mode off: read, whatever "Skip Claude Code keychain access"
    says, which names Claude Code's item only.
  * A copy that cannot be read: skipped.

In the app, Strict privacy mode stops the same kind of read: Zed's keychain item
and the browser-cookie import for a provider set to read cookies automatically
(`PrivacySettings.skipsOtherAppsSecretsOnItsOwn`).

The helper says what it does in its log, once per change ("Claude Code keychain
item: skipped (Strict privacy mode is on in the app)", "Browser cookie stores:
skipped (Strict privacy mode is on in the app)").
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Callable

from local_scan_consent import MirrorRead

logger = logging.getLogger("cli_pulse.privacy_switches")

# The helper's own wait for the copy when it is about to read the item. Short:
# one caller is the managed-session spawn path, and a stalled container read
# must not hold a spawn for the gate's full 10 s. A read that is not done in
# time counts as unreadable, so the item is skipped.
SPAWN_READ_WAIT_S = 1.0


@dataclass(frozen=True)
class KeychainDecision:
    allowed: bool
    # "allowed" | "no_copy" | "strict_privacy_mode" | "skip_claude_keychain" | "unreadable"
    reason: str
    detail: str = ""


def decide_claude_keychain(read: MirrorRead) -> KeychainDecision:
    """May this helper read Claude Code's keychain item? See the module doc."""
    if read.status == "unreadable":
        return KeychainDecision(False, "unreadable", read.detail)
    if read.status == "absent" or (read.skip_claude_keychain is None and read.local_only_mode is None):
        return KeychainDecision(True, "no_copy")
    if read.local_only_mode:
        return KeychainDecision(False, "strict_privacy_mode")
    if read.skip_claude_keychain:
        return KeychainDecision(False, "skip_claude_keychain")
    return KeychainDecision(True, "allowed")


def decide_browser_cookies(read: MirrorRead) -> KeychainDecision:
    """May this helper open browsers' cookie stores and read their "Safe
    Storage" keychain items? Strict privacy mode alone decides it. See the
    module doc."""
    if read.status == "unreadable":
        return KeychainDecision(False, "unreadable", read.detail)
    if read.status == "absent" or (read.skip_claude_keychain is None and read.local_only_mode is None):
        return KeychainDecision(True, "no_copy")
    if read.local_only_mode:
        return KeychainDecision(False, "strict_privacy_mode")
    return KeychainDecision(True, "allowed")


_LOG_TEXT = {
    "allowed": "read when needed (both Privacy switches are off in the app)",
    "no_copy": "read when needed (the app has not copied its Privacy switches: older than 1.55)",
    "strict_privacy_mode": "skipped (Strict privacy mode is on in the app)",
    "skip_claude_keychain": "skipped (Skip Claude Code keychain access is on in the app)",
    "unreadable": "skipped (the app's Privacy switches cannot be read)",
}

_BROWSER_LOG_TEXT = {
    "allowed": "read when needed for claude.ai (Strict privacy mode is off in the app)",
    "no_copy": "read when needed for claude.ai (the app has not copied its Privacy switches: older than 1.55)",
    "strict_privacy_mode": "skipped (Strict privacy mode is on in the app)",
    "unreadable": "skipped (the app's Privacy switches cannot be read)",
}


class _SwitchGate:
    """Asked just before each read a Privacy switch covers. `read` is
    `LocalScanGate.read` in the daemon: the same copy, read the same way, as
    the local-scan answer. Logs what it does once per change."""

    _subject = ""
    _texts: dict[str, str] = {}

    def __init__(self, read: Callable[..., MirrorRead]) -> None:
        self._read = read
        self._lock = threading.Lock()
        self._last: str | None = None

    def _decide(self, read: MirrorRead) -> KeychainDecision:
        raise NotImplementedError

    def check(self, *, wait_s: float | None = None) -> KeychainDecision:
        try:
            read = self._read(wait_s=wait_s)
        except Exception as exc:  # noqa: BLE001 — cannot tell, so do not read
            read = MirrorRead("unreadable", detail=f"{type(exc).__name__}: {exc}")
        decision = self._decide(read)
        self._log_if_changed(decision)
        return decision

    def allows(self, what: str, *, wait_s: float | None = None) -> bool:
        decision = self.check(wait_s=wait_s)
        if not decision.allowed:
            logger.debug("%s not read for %s (%s)", self._subject, what, decision.reason)
        return decision.allowed

    def _log_if_changed(self, decision: KeychainDecision) -> None:
        with self._lock:
            if decision.reason == self._last:
                return
            self._last = decision.reason
        text = self._texts.get(decision.reason, decision.reason)
        if decision.reason == "unreadable" and decision.detail:
            text = f"{text}: {decision.detail}"
        logger.info("%s: %s", self._subject, text)


class ClaudeKeychainGate(_SwitchGate):
    """Asked just before each read of Claude Code's keychain item."""

    _subject = "Claude Code keychain item"
    _texts = _LOG_TEXT

    def _decide(self, read: MirrorRead) -> KeychainDecision:
        return decide_claude_keychain(read)


class BrowserCookieGate(_SwitchGate):
    """Asked just before this helper opens a browser's cookie store, and with
    it reads that browser's "Safe Storage" keychain item, for the claude.ai
    `sessionKey`."""

    _subject = "Browser cookie stores and their Safe Storage keychain items"
    _texts = _BROWSER_LOG_TEXT

    def _decide(self, read: MirrorRead) -> KeychainDecision:
        return decide_browser_cookies(read)

    def strict_privacy_mode(self, *, wait_s: float | None = None) -> bool:
        """Whether the app's copy says Strict privacy mode is on: the switch
        itself, where `allows` is also no for a copy that cannot be read.
        `system_collector` removes the claude.ai cookie it copied earlier only
        on this."""
        return self.check(wait_s=wait_s).reason == "strict_privacy_mode"
