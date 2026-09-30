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

This helper asks cfprefsd for the values first (`app_group_prefs`), because
the file on disk lags the app's writes by up to ten seconds (measured; see that
module), and reads the plist file directly with `plistlib` only when cfprefsd
has no value for any key it asks (an app older than 1.55, or a process macOS
does not let ask). It already lives in that container: its UDS socket and auth
token are there, and it writes the Claude snapshot there every cycle. So
reading one more file costs no new access: the TCC `SystemPolicyAppData` consult that a launchd process pays on
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
  * `cli_pulse_app_account` (`HelperIPC.appAccountKey`, `HelperAccountRecord`):
    which account the app is in, a string: "signed_in:<user id>",
    "local_mode" (CLI Pulse without an account) or "signed_out" (the Sign-In
    form, or Demo mode). The helper's pairing (`~/.cli-pulse-helper.json`)
    outlives a sign-out and an account switch, so a pairing alone does not mean
    the app is still signed in, or signed in as the user it was paired for.
    (A development build of the app once wrote a Bool, `cli_pulse_app_signed_out`,
    instead; no released build did, so it is not read.)
  * `cli_pulse_local_scan_consent_v2` (older history) is not read: this helper
    never reads session logs, so v2 does not change what it may do.
  * `cli_pulse_privacy_skip_claude_keychain` and
    `cli_pulse_privacy_local_only_mode`: Settings › Privacy's two Claude
    keychain switches (`HelperPrivacyInputs.swift`). Read with the rest, and
    decided on in `privacy_switches`, not here: they change which credential
    this helper may read, not whether it may collect.

`MIRROR_KEYS` lists every key read here, and both readers (cfprefsd and the
file) return those keys and no others, so a key left out of it is missing on
both paths, and the tests, which mostly take the file path, see it too.

WHAT EACH COPY MEANS HERE (`decide`)
------------------------------------
The account comes first, as in the built-in helper
(`LocalCollectionPolicy.helperCycle`):

  * "signed_out", or a value this helper does not know (a sign-in with no user
    id included): paused, whatever the answer. The app reads nothing then.
  * "signed_in:<user id>": this helper uploads only with a pairing made for
    that user, as the built-in helper does (`pairedUserId() == userId`). The
    pairing's `user_id` (`paired_user_id_from_config`) is compared with the id
    in the record:
      - the same user: the answer decides, as below.
      - another user: paused. Its uploads would go to the account the pairing
        belongs to, which the app is no longer signed in to. (The built-in
        helper still reads for the app in this case; this helper's only read
        for the app is `hello`, and it gives that up rather than read on
        another account's pairing.)
      - a pairing file that names no user this helper can compare (no
        `user_id`, an empty or non-string one, a file that cannot be read or is
        not JSON): paused, as for another user. `load_config` accepts a config
        whose `user_id` is empty or null, so reading such a pairing as "not
        paired" would upload with a pairing nobody checked.
      - not paired (no pairing file): nothing can be uploaded, so once the
        answer allows it the helper answers the app on this Mac
        (`Cycle.LOCAL`, the built-in helper's `collectLocally`) and its cycle
        does nothing until it is paired. Were the cycle to run, a pairing
        removed between its `load_config` and its last check would upload
        with a pairing that check never saw.
      - just before an upload: a step sends with the pairing it loaded before
        it started reading, so that check is given the pairing too
        (`LocalScanGate.check(sending=...)`, `pairing_sent_with`). The file
        must still be paired for the user the loaded pairing names (paused,
        "pairing_changed", otherwise), and that user is the one compared with
        the record. Checking the file alone, a `pair` for another user run
        while the step reads, together with a switch to that account, would
        pass, and the step would upload with the old pairing to the old
        account. The built-in helper binds the pairing it verified to its
        upload steps (`HelperCycleRunner`) for the same reason.
  * "local_mode": reads for the app on this Mac only after "granted"
    (`Cycle.LOCAL`: the UDS `hello` may read, the cycle uploads nothing and so
    reads nothing either); anything else, paused. Without an account an
    unanswered question is not a yes (`LocalCollectionPolicy.allowsCollection`).
  * With an account record, the app is 1.55 or newer, so a missing answer is
    not an older app speaking: paused until the app writes it.

Then the answer:

  * No copy at all (no plist, or neither the consent key nor the account key):
    the app is older than 1.55, which never writes one. Old apps also offer
    this helper as an update, so the helper does what it did before
    (`Cycle.LEGACY`). This is where it differs on purpose from the built-in
    helper, which waits for a copy: that helper ships inside the app, so its
    app always writes one; this one may be paired with an app that never will.
  * "declined", or a value this helper does not know: paused.
  * "granted", or "undecided" while signed in as the pairing's user (or with no
    account record, where the pairing is trusted as before the record
    existed): collect and upload, as before
    (`LocalCollectionPolicy.allowsCollection`: no answer lets a signed-in
    account through; a helper that is not paired sends nothing anyway).
  * A plist that is there but cannot be read (permission denied, a stalled
    container, corrupt data): paused, and it stays paused for as long as the
    file cannot be read. Every check tries again, so a container that was only
    slow resumes once its access completes; one that macOS denies (TCC answered
    no) stays paused for the life of the helper process. The answer might be
    "Not now", and a pre-1.55 app's plist looks the same from outside, so
    neither case is read as "no copy".

Paused means the cycle does nothing at all: no process list, no Keychain, no
provider call, no token refresh, no credential file rewritten, no `claude
/usage` run, no Claude snapshot written, and nothing sent, not even the
heartbeat. The UDS `hello` reply asks the same gate and leaves out
`provider_plan_status`, which would read `~/.codex/auth.json`. A heartbeat would
report this cycle's session count and device metrics, which a paused helper did
not measure, and `helper_sync` with no sessions is not a no-op on the server
(it ends this device's running sessions). Leaving the device row alone lets it
age, which is how the other devices show a Mac that is not reporting.

Local (`Cycle.LOCAL`: local mode after a yes, or signed in with no pairing)
is paused for the cycle, whose every step uploads, and open for the UDS
`hello`, which answers only the app on this Mac.
"""
from __future__ import annotations

import enum
import json
import logging
import plistlib
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import app_group_prefs
from local_auth_token import APP_GROUP_ID, container_path

logger = logging.getLogger("cli_pulse.local_scan_consent")

CONSENT_KEY = "cli_pulse_local_scan_consent"
# `HelperIPC.appAccountKey`: "signed_in:<uid>" | "local_mode" | "signed_out".
APP_ACCOUNT_KEY = "cli_pulse_app_account"
# Settings › Privacy's switches (see `privacy_switches`).
SKIP_CLAUDE_KEYCHAIN_KEY = "cli_pulse_privacy_skip_claude_keychain"
LOCAL_ONLY_MODE_KEY = "cli_pulse_privacy_local_only_mode"

# Everything this helper reads from the app's copy. Both readers return these
# keys and no others (`_mirror_from`), so a key missing here is missing on the
# file path the tests take as well as on the cfprefsd path production takes.
MIRROR_KEYS = (CONSENT_KEY, APP_ACCOUNT_KEY, SKIP_CLAUDE_KEYCHAIN_KEY, LOCAL_ONLY_MODE_KEY)

# `HelperAccountRecord.storedValue`.
SIGNED_IN_PREFIX = "signed_in:"
LOCAL_MODE = "local_mode"
SIGNED_OUT = "signed_out"

# The Companion's pairing, as `cli_pulse_helper.CONFIG_PATH` names it; read
# here for its `user_id` only (`paired_user_id_from_config`).
PAIRING_FILENAME = ".cli-pulse-helper.json"

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
    # The raw value under `APP_ACCOUNT_KEY`, or None when the key is not there.
    account: object = None
    detail: str = ""
    # Settings › Privacy's switches: None when the key is not there.
    skip_claude_keychain: bool | None = None
    local_only_mode: bool | None = None
    # "cfprefsd" or "file": where an "ok" read came from.
    source: str = "file"


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


def _optional_bool(values: dict, key: str) -> bool | None:
    return _as_bool(values[key]) if key in values else None


def _mirror_from(values: dict, source: str) -> MirrorRead:
    # Only `MIRROR_KEYS`, whichever reader produced `values`: cfprefsd is asked
    # for those keys alone, and the file must not see more than it does.
    values = {key: values[key] for key in MIRROR_KEYS if key in values}
    return MirrorRead(
        "ok",
        consent=values.get(CONSENT_KEY),
        account=values.get(APP_ACCOUNT_KEY),
        skip_claude_keychain=_optional_bool(values, SKIP_CLAUDE_KEYCHAIN_KEY),
        local_only_mode=_optional_bool(values, LOCAL_ONLY_MODE_KEY),
        source=source,
    )


def read_mirror(path: Path | None = None) -> MirrorRead:
    """Read the app's copy of its answers. Never raises.

    cfprefsd first, which answers with what the app last wrote; the plist file
    when cfprefsd has no value for any of `MIRROR_KEYS` (see the module doc)."""
    if path is None:
        path = mirror_plist_path()
    live = app_group_prefs.copy_values(path, MIRROR_KEYS)
    if live is not None:
        return _mirror_from(live, "cfprefsd")
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except FileNotFoundError:
        return MirrorRead("absent")
    except Exception as exc:  # noqa: BLE001 — any failure is "cannot tell"
        return MirrorRead("unreadable", detail=f"{type(exc).__name__}: {exc}")
    if not isinstance(data, dict):
        return MirrorRead("unreadable", detail=f"top level is {type(data).__name__}, not a dictionary")
    return _mirror_from(data, "file")


# ── the decision ───────────────────────────────────────────────


class Cycle(enum.Enum):
    COLLECT = "collect"  # the answer allows it: collect and sync as before
    LEGACY = "legacy"  # no copy (an app older than 1.55): as before
    # Local mode after a yes, or signed in with no pairing to upload with: the
    # UDS `hello` may read for the app on this Mac; the cycle, which uploads,
    # does nothing.
    LOCAL = "local"
    PAUSED = "paused"  # read nothing, write nothing, send nothing


@dataclass(frozen=True)
class Decision:
    cycle: Cycle
    # "granted" | "undecided" | "no_copy" | "local_mode" | "not_paired" |
    # "declined" | "signed_out" | "other_account" | "unverified_pairing" |
    # "pairing_changed" | "no_answer" | "undecided_local_mode" |
    # "unrecognised" | "unreadable"
    reason: str
    detail: str = ""

    @property
    def allows_collection(self) -> bool:
        """May this helper read this Mac at all (for the app, or to upload)?"""
        return self.cycle is not Cycle.PAUSED

    @property
    def allows_upload(self) -> bool:
        """May a cycle read and send: heartbeat, sync, the git scan?"""
        return self.cycle in (Cycle.COLLECT, Cycle.LEGACY)


class UnusablePairing(Exception):
    """There is a pairing file, but it names no user this helper can compare
    with the app's account: it cannot be read, is not JSON, or its `user_id`
    is missing, empty or not a string."""


def paired_user_id_from_config() -> str | None:
    """The user this Mac's Companion was paired for: `user_id` in
    `~/.cli-pulse-helper.json` (`cli_pulse_helper.HelperConfig`), read afresh.

    None only when there is no pairing file: not paired, so nothing can be
    uploaded (`load_config` raises). A file that is there but names no usable
    user raises `UnusablePairing` rather than reading as "not paired":
    `load_config` loads a config whose `user_id` is "" or null, and uploads
    with it, so such a pairing is one the helper cannot check, not one it
    lacks."""
    path = Path.home() / PAIRING_FILENAME
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return None
    except Exception as exc:  # noqa: BLE001 — there, but cannot be checked
        raise UnusablePairing(f"{path} cannot be read ({type(exc).__name__}: {exc})") from exc
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise UnusablePairing(f"{path} is not JSON ({exc})") from exc
    user_id = data.get("user_id") if isinstance(data, dict) else None
    if not isinstance(user_id, str) or not user_id.strip():
        raise UnusablePairing(f"{path} names no user id ({user_id!r:.40})")
    return user_id


class PairingChanged(UnusablePairing):
    """The pairing file no longer names the user of the pairing a step loaded
    and is about to upload with: `pair` ran while the step was reading."""


def _same_user(a: str, b: str) -> bool:
    # Supabase user ids are UUIDs; a UUID is the same id in either case.
    return a.strip().lower() == b.strip().lower()


def pairing_sent_with(
    sending: object,
    on_disk: Callable[[], str | None] = paired_user_id_from_config,
) -> Callable[[], str | None]:
    """The pairing reader for the check just before a step uploads.

    `sending` is the pairing (a `cli_pulse_helper.HelperConfig`) the step
    loaded before it started reading, and the one its upload is sent with.
    The file (`on_disk`) may have been rewritten since, so both are asked:

      * the file not paired any more (None): returned as is, so a sign-in
        uploads nothing (`not_paired`), as for a check of the file alone;
      * the file naming no usable user: returned as is (`decide` pauses);
      * `sending` naming no usable user: `UnusablePairing`;
      * the two naming different users: `PairingChanged`;
      * otherwise the user they both name, which `decide` compares with the
        app's record.
    """

    def read() -> str | None:
        current = on_disk()
        if current is None or not isinstance(current, str) or not current.strip():
            return current
        sent = getattr(sending, "user_id", None)
        if not isinstance(sent, str) or not sent.strip():
            raise UnusablePairing(f"the pairing this step sends with names no user id ({sent!r:.40})")
        if not _same_user(current, sent):
            raise PairingChanged("this Mac was paired again after this step loaded its pairing")
        return sent

    return read


def _decide_answer(consent: object) -> Decision:
    if consent == DECLINED:
        return Decision(Cycle.PAUSED, "declined")
    if consent == GRANTED:
        return Decision(Cycle.COLLECT, "granted")
    if consent == UNDECIDED:
        return Decision(Cycle.COLLECT, "undecided")
    # Written by an app newer than this helper, or damaged. Reading it as "no
    # copy" would collect; the built-in helper reads it as no answer too.
    return Decision(Cycle.PAUSED, "unrecognised", repr(consent)[:80])


def decide(
    read: MirrorRead,
    paired_user_id: Callable[[], str | None] = paired_user_id_from_config,
) -> Decision:
    """What one cycle may do, given what the app's copy held. See the module
    doc. `paired_user_id` (the pairing's user id; None when not paired; raises
    for a pairing it cannot check) is asked only for a "signed_in:" record."""
    if read.status == "unreadable":
        return Decision(Cycle.PAUSED, "unreadable", read.detail)
    account = read.account
    if account is None:
        # No record: an app older than 1.55, or one from before the record.
        if read.status == "absent" or read.consent is None:
            return Decision(Cycle.LEGACY, "no_copy")
        return _decide_answer(read.consent)

    # Only an app that writes the copy writes this key, so from here on even a
    # missing answer is not a pre-1.55 app speaking.
    if account == LOCAL_MODE:
        if read.consent == GRANTED:
            return Decision(Cycle.LOCAL, "local_mode")
        if read.consent is None:
            return Decision(Cycle.PAUSED, "no_answer")
        if read.consent == UNDECIDED:
            return Decision(Cycle.PAUSED, "undecided_local_mode")
        return _decide_answer(read.consent)  # declined, or unrecognised
    user_id = ""
    if isinstance(account, str) and account.startswith(SIGNED_IN_PREFIX):
        user_id = account[len(SIGNED_IN_PREFIX):]
    if not user_id.strip():
        # "signed_out", a sign-in with no user, or a value this helper does not
        # know (`HelperAccountRecord(storedValue:)` reads those as signed out).
        detail = "" if account == SIGNED_OUT else repr(account)[:80]
        return Decision(Cycle.PAUSED, "signed_out", detail)
    # Upload only with a pairing made for this user (the built-in helper's
    # `pairedUserId() == userId`).
    try:
        paired = paired_user_id()
    except PairingChanged as exc:
        return Decision(Cycle.PAUSED, "pairing_changed", str(exc)[:160])
    except Exception as exc:  # noqa: BLE001 — a pairing that cannot be checked
        return Decision(Cycle.PAUSED, "unverified_pairing", str(exc)[:160])
    if paired is not None:
        if not isinstance(paired, str) or not paired.strip():
            return Decision(Cycle.PAUSED, "unverified_pairing", repr(paired)[:80])
        if not _same_user(paired, user_id):
            return Decision(Cycle.PAUSED, "other_account")
    if read.consent is None:
        return Decision(Cycle.PAUSED, "no_answer")
    decision = _decide_answer(read.consent)
    if paired is None and decision.cycle is Cycle.COLLECT:
        # Not paired: answer the app on this Mac, upload nothing.
        return Decision(Cycle.LOCAL, "not_paired")
    return decision


# ── the gate the daemon asks ───────────────────────────────────


class LocalScanGate:
    """Asked at the start of every cycle and again before anything the cycle
    collected is written or sent, so an answer given mid-cycle drops what that
    cycle read instead of uploading it. The UDS `hello` handler asks it too,
    on its own thread and with a shorter wait.

    Every check reads the plist again: the helper holds no copy of the answer,
    so a change reaches it at the next check with nothing to invalidate. The
    pairing's user id is read again too, and only for a "signed_in:" record
    (`paired_user_id`, `paired_user_id_from_config` unless a test says).

    The cycle's steps ask `allows_upload`, and just before an upload pass the
    pairing they will send with (`sending`, see `pairing_sent_with`); the UDS
    `hello`, which answers the app on this Mac, and the reads and writes
    inside a cycle ask `allows_collection`.
    """

    def __init__(
        self,
        *,
        path: Callable[[], Path] = mirror_plist_path,
        reader: Callable[[Path], MirrorRead] = read_mirror,
        read_wait_s: float = READ_WAIT_S,
        container_ready: Callable[[], bool] = lambda: True,
        paired_user_id: Callable[[], str | None] = paired_user_id_from_config,
    ) -> None:
        self._path = path
        self._paired_user_id = paired_user_id
        self._reader = reader
        self._read_wait_s = read_wait_s
        self._container_ready = container_ready
        self._lock = threading.Lock()
        self._pending: tuple[threading.Thread, dict] | None = None
        self._last: tuple[Cycle, str] | None = None

    def check(
        self, *, wait_s: float | None = None, sending: object = None, log: bool = True
    ) -> Decision:
        """The decision for now. `wait_s` bounds how long this check waits for
        the plist read (default `READ_WAIT_S`); a read that is not done by then
        counts as unreadable, so this check pauses.

        `sending`, when given, is the pairing the caller loaded and is about to
        upload with: a sign-in then also needs the file to still be paired
        for that pairing's user (`pairing_sent_with`).

        `log` False leaves the decision out of this gate's once-per-change
        log line: for a caller that asks about a different pairing than the
        cycle does (the remote command poll, about once a second) and logs its
        own, so the two questions do not overwrite each other's last line."""
        paired_user_id = (
            self._paired_user_id if sending is None
            else pairing_sent_with(sending, self._paired_user_id)
        )
        decision = decide(
            self._read(self._read_wait_s if wait_s is None else wait_s),
            paired_user_id,
        )
        if log:
            self._log_if_changed(decision)
        return decision

    def allows_collection(self, *, wait_s: float | None = None) -> bool:
        return self.check(wait_s=wait_s).allows_collection

    def allows_upload(self, *, wait_s: float | None = None, sending: object = None) -> bool:
        return self.check(wait_s=wait_s, sending=sending).allows_upload

    def read(self, *, wait_s: float | None = None) -> MirrorRead:
        """The app's copy as it is now, read the way `check` reads it (bounded
        wait, one pending read at a time, nothing while the container is not
        reachable). For `privacy_switches`, which decides on other keys."""
        return self._read(self._read_wait_s if wait_s is None else wait_s)

    def _read(self, wait_s: float) -> MirrorRead:
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
            if self._pending is not None and not self._pending[0].is_alive():
                # A read an earlier check gave up on has finished since. Its
                # answer is as old as that finish, and the user may have
                # answered again after it, so it is dropped. The access it was
                # waiting for is paid now, so the fresh read below is quick.
                self._pending = None
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
        worker.join(wait_s)
        if worker.is_alive():
            return MirrorRead(
                "unreadable",
                detail=f"reading the app's answer did not finish within {wait_s:g}s",
            )
        with self._lock:
            if self._pending is not None and self._pending[0] is worker:
                self._pending = None
        return box.get("read") or MirrorRead("unreadable", detail="no result")

    def _log_if_changed(self, decision: Decision) -> None:
        # The daemon's cycle and the UDS `hello` handler both ask this gate, on
        # different threads.
        key = (decision.cycle, decision.reason)
        with self._lock:
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
        elif decision.reason == "not_paired":
            logger.info(
                "the app is signed in and allows the local scan, but this helper is "
                "not paired: answering the app on this Mac, uploading nothing until "
                "it is paired"
            )
        elif decision.cycle is Cycle.LOCAL:
            logger.info(
                "the app is in local mode (no account) and allows the local scan: "
                "answering it on this Mac, uploading nothing"
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
                _PAUSE_TEXT.get(decision.reason, decision.reason),
                f": {decision.detail}" if decision.detail else "",
            )


_PAUSE_TEXT = {
    "signed_out": "signed out",
    "other_account": "signed in to an account this Mac was not paired for",
    "unverified_pairing": "signed in, and this Mac's pairing does not say which account it is for",
    "pairing_changed": "this Mac was paired again while a step was reading; "
                       "what it read with the old pairing is dropped",
    "no_answer": "no answer written yet",
    "undecided_local_mode": "local mode, not answered yet",
}
