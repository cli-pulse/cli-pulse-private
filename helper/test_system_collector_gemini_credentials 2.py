from __future__ import annotations

import errno
import json
import os
import time
from pathlib import Path

import pytest

import system_collector


def _configure_paths(monkeypatch, tmp_path: Path) -> tuple[Path, Path]:
    tokens_path = tmp_path / ".config" / "clipulse" / "gemini_tokens.json"
    lock_path = tmp_path / "group" / ".gemini-credential.lock"
    monkeypatch.setattr(
        system_collector,
        "_clipulse_gemini_tokens_path",
        lambda: tokens_path,
    )
    monkeypatch.setattr(
        system_collector,
        "_clipulse_gemini_lock_path",
        lambda: lock_path,
    )
    return tokens_path, lock_path


def _write_tokens(
    path: Path,
    *,
    access_token: str = "committed-access",
    expiry_date: int | None = None,
    extra: dict | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "generation": "11111111-1111-4111-8111-111111111111",
        "access_token": access_token,
        "client_id":
            system_collector
                ._CLIPULSE_GEMINI_CLIENT_ID,
        "expiry_date": expiry_date
        if expiry_date is not None
        else int((time.time() + 3600) * 1000),
    }
    payload.update(extra or {})
    path.write_text(json.dumps(payload), encoding="utf-8")
    path.chmod(0o600)


def test_committed_clipulse_gemini_snapshot_is_read_under_shared_lock(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, lock_path = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(tokens_path)

    assert (
        system_collector._try_read_gemini_token(tokens_path)
        == "committed-access"
    )
    assert (
        system_collector._get_clipulse_gemini_client_id()
        == system_collector
        ._CLIPULSE_GEMINI_CLIENT_ID
    )
    assert lock_path.is_file()
    assert lock_path.stat().st_mode & 0o777 == 0o600
    assert lock_path.parent.stat().st_mode & 0o777 == 0o700


def test_transaction_marker_hides_stale_live_snapshot(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(tokens_path, access_token="must-not-leak")
    marker_path = Path(f"{tokens_path}.transaction")
    marker_path.write_text('{"version":1}', encoding="utf-8")
    marker_path.chmod(0o600)

    assert system_collector._try_read_gemini_token(tokens_path) is None
    assert system_collector._get_clipulse_gemini_client_id() == ""


def test_corrupt_or_broken_symlink_marker_also_fails_closed(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(tokens_path, access_token="must-not-leak")
    marker_path = Path(f"{tokens_path}.transaction")
    marker_path.symlink_to(tmp_path / "missing-marker-target")

    assert os.path.lexists(marker_path)
    assert system_collector._try_read_gemini_token(tokens_path) is None


def test_insecure_clipulse_token_file_is_rejected(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(tokens_path)
    tokens_path.chmod(0o644)

    assert system_collector._try_read_gemini_token(tokens_path) is None


def test_group_writable_clipulse_directory_is_rejected(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(tokens_path)
    tokens_path.parent.chmod(0o770)

    assert system_collector._try_read_gemini_token(tokens_path) is None


@pytest.mark.parametrize(
    "invalid_fields",
    [
        {"version": True},
        {"version": 0},
        {"generation": "not-a-uuid"},
        {
            "generation":
                "11111111-1111-4111-8111-11111111111A",
        },
        {"access_token": ""},
        {"access_token": " surrounded "},
        {"client_id": "another-client"},
        {"expiry_date": "2100000000000"},
        {"expiry_date": float("nan")},
        {"expiry_date": float("inf")},
        {"expiry_date": 1},
        {"refresh_token": "must-not-be-present"},
    ],
)
def test_clipulse_snapshot_requires_strict_v1_schema(
    monkeypatch,
    tmp_path: Path,
    invalid_fields: dict,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(
        tokens_path,
        extra=invalid_fields,
    )

    assert system_collector._try_read_gemini_token(tokens_path) is None
    assert system_collector._get_clipulse_gemini_client_id() == ""


def test_legacy_snapshot_without_version_and_generation_is_rejected(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    tokens_path.parent.mkdir(parents=True, exist_ok=True)
    tokens_path.write_text(
        json.dumps(
            {
                "access_token": "legacy-access",
                "client_id":
                    system_collector
                        ._CLIPULSE_GEMINI_CLIENT_ID,
                "expiry_date":
                    int((time.time() + 3600) * 1000),
            }
        ),
        encoding="utf-8",
    )
    tokens_path.chmod(0o600)

    assert system_collector._try_read_gemini_token(tokens_path) is None


def test_hard_linked_lock_is_rejected_before_chmod(
    monkeypatch,
    tmp_path: Path,
) -> None:
    _, lock_path = _configure_paths(monkeypatch, tmp_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    target = tmp_path / "lock-target"
    target.write_text("target", encoding="utf-8")
    target.chmod(0o644)
    os.link(target, lock_path)

    with system_collector._clipulse_gemini_credential_lock() as acquired:
        assert acquired is False
    assert target.stat().st_mode & 0o777 == 0o644


def test_shared_lock_timeout_fails_closed(
    monkeypatch,
    tmp_path: Path,
) -> None:
    _configure_paths(monkeypatch, tmp_path)

    def always_busy(_descriptor: int, operation: int) -> None:
        if operation & system_collector._fcntl.LOCK_EX:
            raise BlockingIOError(errno.EAGAIN, "busy")

    monkeypatch.setattr(system_collector._fcntl, "lockf", always_busy)
    with system_collector._clipulse_gemini_credential_lock(
        timeout_seconds=0
    ) as acquired:
        assert acquired is False


def test_helper_never_refreshes_clipulse_shared_file(
    monkeypatch,
    tmp_path: Path,
) -> None:
    tokens_path, _ = _configure_paths(monkeypatch, tmp_path)
    _write_tokens(
        tokens_path,
        access_token="expired-access",
        expiry_date=1_500_000_000_000,
    )

    def unexpected_network(*_args, **_kwargs):
        pytest.fail("Helper attempted to refresh Swift-owned credentials")

    monkeypatch.setattr(
        system_collector.urllib.request,
        "urlopen",
        unexpected_network,
    )
    before = tokens_path.read_bytes()

    assert system_collector._try_read_gemini_token(tokens_path) is None
    assert tokens_path.read_bytes() == before
