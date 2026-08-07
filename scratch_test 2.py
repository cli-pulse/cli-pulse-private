import os
import time
from pathlib import Path

# mock
class h:
    os = os
    Path = Path

def _read_respawn_count(counter_path: Path) -> int:
    try:
        return int(counter_path.read_text().strip() or "0")
    except Exception:
        return 0

def _write_respawn_count(counter_path: Path, value: int) -> None:
    try:
        counter_path.parent.mkdir(parents=True, exist_ok=True)
        counter_path.write_text(str(value))
    except Exception as exc:
        print("write failed:", exc)

def _rotate_token_or_respawn(max_respawns=3):
    import threading
    counter_path = Path("/tmp/nope/deep/.count") # will fail to write if parent doesn't exist
    box = {}
    def _run():
        time.sleep(1.0)
    worker = threading.Thread(target=_run)
    worker.start()
    worker.join(0.1)

    if not worker.is_alive():
        return "TOKEN"

    attempts = _read_respawn_count(counter_path) + 1

    if attempts <= max_respawns:
        _write_respawn_count(counter_path, attempts)
        return "EXIT 75"

    _write_respawn_count(counter_path, 0)
    return "DEGRADED"

print("Boot 1:", _rotate_token_or_respawn())
print("Boot 2:", _rotate_token_or_respawn())
print("Boot 3:", _rotate_token_or_respawn())
print("Boot 4:", _rotate_token_or_respawn())
