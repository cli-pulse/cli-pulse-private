"""The Mac app's local-scan answer, as the Companion CLI reads it.

Since consent v2 the Mac app asks before CLI Pulse reads this Mac, and a user
can answer "Not now". The app keeps that answer in its own defaults, which this
helper cannot read, so until 1.55 the Companion CLI went on collecting whatever
the answer was: every cycle it listed processes, read the Claude Keychain item,
`~/.codex/auth.json` and browser cookie stores, refreshed provider tokens, and
sent `helper_heartbeat` + `helper_sync`.

WHERE THE ANSWER COMES FROM
---------------------------
From 1.55 the app copies the answer into its app-group defaults
(`LocalScanConsentStore.mirror`, suite `group.yyh.CLI-Pulse`), for its built-in
LoginItem helper. On disk that suite is a cfprefsd plist inside the app-group
container:

    ~/Library/Group Containers/group.yyh.CLI-Pulse/Library/Preferences/
        group.yyh.CLI-Pulse.plist

That is where both builds of the app keep it. The App Store build is sandboxed;
the Developer ID build is not, but it carries the app-group entitlement, and
cfprefsd puts an entitled process's group suite in the group container too.
(A process WITHOUT the entitlement, such as `swift test`, gets
`~/Library/Preferences/group.yyh.CLI-Pulse.plist` instead. That file is not the
app's and is never read here.)

This helper reads the plist file directly with `plistlib`. It already lives in
that container: its UDS socket and auth token are there, and it writes the
Claude snapshot there every cycle. So reading one more file costs no new
access: the TCC `SystemPolicyAppData` consult that a launchd process pays on
its first container access (see `_CONTAINER_ACCESS_WAIT_S` in
`cli_pulse_helper`) has already been paid at startup, and it is per process.
That stops being true if the socket and token ever leave the container, as the
bundled Swift helper's did to end the "would like to access data from other
apps" prompt: this read would then be the helper's only container access, and
the answer would need another way in (a file next to the socket, or a UDS verb).

The keys are the app's (`LocalScanConsent.swift`, `HelperIPC.swift`):

  * `cli_pulse_local_scan_consent`: "undecided" | "granted" | "declined". The
    copy always holds one of these; the app writes "undecided" too, so a
    missing key means the app has not written a copy at all.
  * `cli_pulse_app_signed_out`: true from a sign-out (or a launch with no
    session to restore) until the next sign-in. The helper's pairing outlives a
    sign-out, so a pairing alone does not mean the account is still signed in.
  * `cli_pulse_local_scan_consent_v2` (older history) is not read: this helper
    never reads session logs, so v2 does not change what it may do.

WHAT EACH ANSWER MEANS HERE (`decide`)
--------------------------------------
  * No copy (no plist, or no consent key): the app is older than 1.55, which
    never writes one. Old apps also offer this helper as an update, so the
    helper does what it did before (`Cycle.LEGACY`). This is where it differs on
    purpose from the built-in helper, which waits for a copy: that helper ships
    inside the app, so its app always writes one; this one may be paired with an
    app that never will.
  * "declined", a sign-out, or a value this helper does not know: paused.
  * "granted", or "undecided" on a paired Mac that has not signed out: collect,
    as before (`LocalCollectionPolicy.allowsCollection`: no answer lets a
    signed-in account through; a helper that is not paired sends nothing
    anyway).
  * A plist that is there but cannot be read (permission denied, a stalled
    container, corrupt data): paused for this cycle. The answer might be
    "Not now", and a pre-1.55 app's plist looks the same from outside.

Paused means the cycle does nothing at all: no process list, no Keychain, no
provider call, no token refresh, no credential file rewritten, no Claude
snapshot written, and nothing sent, not even the heartbeat. A heartbeat would
report this cycle's session count and device metrics, which a paused helper did
not measure, and `helper_sync` with no sessions is not a no-op on the server
(it ends this device's running sessions). Leaving the device row alone lets it
age, which is how the other devices show a Mac that is not reporting.
"""
from __future__ import annotations

import enum
import logging
import plistlib
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from local_auth_token import APP_GROUP_ID, container_path

logger = logging.getLogger("cli_pulse.local_scan_consent")

CONSENT_KEY = "cli_pulse_local_scan_consent"
APP_SIGNED_OUT_KEY = "cli_pulse_app_signed_out"

GRANTED = "granted"
DECLINED = "declined"
UNDECIDED = "undecided"

# How long one check waits for the plist read. The read runs on a daemon thread
# (like `_rotate_token_best_effort`), so a container access that stalls costs
# the cycle this long and no more. A read still pending is waited on again by
# the next check rather than started twice: each new access to a stalled
# container is a new TCC consult.
READ_WAIT_S = 10.0


def mirror_plist_path() -> Path:
    """The app-group defaults plist the app copies its answer into."""
    return container_path() / "Library" / "Preferences" / f"{APP_GROUP_ID}.plist"


# ── reading the copy ───────────────────────────────────────────


@dataclass(frozen=True)
class MirrorRead:
    """What the plist held, before any policy is applied.

    `status` is "ok" (parsed), "absent" (no file, or no container: no app has
    written its group defaults here) or "unreadable". With "ok", `consent` is
    the raw value under `CONSENT_KEY`, or None when the key is not there.
    """

    status: str
    consent: object = None
    signed_out: bool = False
    detail: str = ""


def _as_bool(value: object) -> bool:
    """`UserDefaults.bool(forKey:)`: true for true, a non-zero number, or the
    strings "YES"/"true"/"1" (any case); false for anything else or nothing."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("yes", "true", "1")
    return False


def read_mirror(path: Path | None = None) -> MirrorRead:
    """Read the app's copy of its answers. Never raises."""
    if path is None:
        path = mirror_plist_path()
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except FileNotFoundError:
        return MirrorRead("absent")
    except Exception as exc:  # noqa: BLE001 — any failure is "cannot tell"
        return MirrorRead("unreadable", detail=f"{type(exc).__name__}: {exc}")
    if not isinstance(data, dict):
        return MirrorRead("unreadable", detail=f"top level is {type(data).__name__}, not a dictionary")
    return MirrorRead(
        "ok",
        consent=data.get(CONSENT_KEY),
        signed_out=_as_bool(data.get(APP_SIGNED_OUT_KEY)),
    )


# ── the decision ───────────────────────────────────────────────


class Cycle(enum.Enum):
    COLLECT = "collect"  # the answer allows it: collect and sync as before
    LEGACY = "legacy"  # no copy (an app older than 1.55): as before
    PAUSED = "paused"  # read nothing, write nothing, send nothing


@dataclass(frozen=True)
class Decision:
    cycle: Cycle
    # "granted" | "undecided" | "no_copy" | "declined" | "signed_out" |
    # "unrecognised" | "unreadable"
    reason: str
    detail: str = ""

    @property
    def allows_collection(self) -> bool:
        return self.cycle is not Cycle.PAUSED


def decide(read: MirrorRead) -> Decision:
    """What one cycle may do, given what the plist held. See the module doc."""
    if read.status == "unreadable":
        return Decision(Cycle.PAUSED, "unreadable", read.detail)
    if read.signed_out:
        # Checked before the answer: a signed-out Mac never uploads, and only an
        # app that writes the copy writes this key, so even without a consent
        # key it is not a pre-1.55 app speaking.
        return Decision(Cycle.PAUSED, "signed_out")
    if read.status == "absent" or read.consent is None:
        return Decision(Cycle.LEGACY, "no_copy")
    if read.consent == DECLINED:
        return Decision(Cycle.PAUSED, "declined")
    if read.consent == GRANTED:
        return Decision(Cycle.COLLECT, "granted")
    if read.consent == UNDECIDED:
        return Decision(Cycle.COLLECT, "undecided")
    # Written by an app newer than this helper, or damaged. Reading it as "no
    # copy" would collect; the built-in helper reads it as no answer too.
    return Decision(Cycle.PAUSED, "unrecognised", repr(read.consent)[:80])


# ── the gate the daemon asks ───────────────────────────────────


class LocalScanGate:
    """Asked at the start of every cycle and again before anything the cycle
    collected is written or sent, so an answer given mid-cycle drops what that
    cycle read instead of uploading it.

    Every check reads the plist again: the helper holds no copy of the answer,
    so a change reaches it at the next check with nothing to invalidate.
    """

    def __init__(
        self,
        *,
        path: Callable[[], Path] = mirror_plist_path,
        reader: Callable[[Path], MirrorRead] = read_mirror,
        read_wait_s: float = READ_WAIT_S,
        container_ready: Callable[[], bool] = lambda: True,
    ) -> None:
        self._path = path
        self._reader = reader
        self._read_wait_s = read_wait_s
        self._container_ready = container_ready
        self._lock = threading.Lock()
        self._pending: tuple[threading.Thread, dict] | None = None
        self._last: tuple[Cycle, str] | None = None

    def check(self) -> Decision:
        decision = decide(self._read())
        self._log_if_changed(decision)
        return decision

    def allows_collection(self) -> bool:
        return self.check().allows_collection

    def _read(self) -> MirrorRead:
        try:
            ready = self._container_ready()
        except Exception:  # noqa: BLE001 — cannot tell, so do not touch it
            ready = False
        if not ready:
            # The startup token rotation is still stuck in its container access
            # (see `_rotate_token_best_effort`). Another access now would be a
            # second consult on a stalled container.
            return MirrorRead("unreadable", detail="app-group container not reachable yet")
        with self._lock:
            if self._pending is None:
                box: dict = {}
                path = self._path()

                def _run() -> None:
                    try:
                        box["read"] = self._reader(path)
                    except BaseException as exc:  # noqa: BLE001 — reported as unreadable
                        box["read"] = MirrorRead("unreadable", detail=f"{type(exc).__name__}: {exc}")

                worker = threading.Thread(target=_run, name="local-scan-consent-read", daemon=True)
                self._pending = (worker, box)
                worker.start()
            worker, box = self._pending
        worker.join(self._read_wait_s)
        if worker.is_alive():
            return MirrorRead(
                "unreadable",
                detail=f"reading the app's answer did not finish within {self._read_wait_s:.0f}s",
            )
        with self._lock:
            if self._pending is not None and self._pending[0] is worker:
                self._pending = None
        return box.get("read") or MirrorRead("unreadable", detail="no result")

    def _log_if_changed(self, decision: Decision) -> None:
        key = (decision.cycle, decision.reason)
        if key == self._last:
            return
        self._last = key
        if decision.cycle is Cycle.COLLECT:
            logger.info("local scan allowed by the app (answer: %s)", decision.reason)
        elif decision.cycle is Cycle.LEGACY:
            logger.info(
                "no local-scan answer from the app at %s (apps older than 1.55 do "
                "not write one): collecting as before",
                self._path(),
            )
        elif decision.reason == "unreadable":
            logger.warning(
                "cannot read the app's local-scan answer (%s): paused, reading and "
                "sending nothing until it can be read",
                decision.detail,
            )
        else:
            logger.info(
                "local scan paused by the app (%s%s): reading and sending nothing",
                decision.reason,
                f": {decision.detail}" if decision.detail else "",
            )
