#!/usr/bin/env python3
"""Differentially compare the Swift helper's machine snapshot against the Python one.

Why this exists rather than "look at the Machine tab": the client's
`MachineSnapshot(dict:)` is non-failable and non-throwing, with `?? 0` / `?? [:]`
/ `?? -1` on every field, and the tab shows its error UI only when the CALL
threw. So a successful response carrying a wrong-shaped dict does not surface as
an error — it renders a confident "0% CPU, 0% memory, no battery" cockpit. The
tab looking populated proves nothing; only a field-by-field diff does.

Comparison is by field class, because most of these values legitimately change
between the two calls:

  exact      key sets, types, and values that cannot drift in a second
  tolerance  values that drift slowly (memory %, uptime, charge)
  shape-only values that are volatile by definition (cpu %, load, power, temps)

Never byte-diff the JSON: JSONSerialization writes Double(0.007) as
0.0070000000000000001 where Python's json writes 0.007. Identical numbers,
different text.

Usage:
    scripts/dev/diff_machine_snapshot.py [--swift-binary PATH]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SWIFT_BIN = REPO / "HelperSwift" / ".build" / "debug" / "cli_pulse_helper"

# value-class -> (absolute tolerance, or None for shape-only)
SLOW_DRIFT = {
    "memory_percent": 5,
    "system.uptime_seconds": 3,
    "battery.charge_pct": 2,
    "battery.health_pct": 0.5,
    "battery.battery_temp_c": 5.0,
    "memory_used_bytes": None,      # moves constantly; shape only
    "system.disk_free_bytes": None,
    "system.swap_used_bytes": None,
}

# Volatile by definition — assert type and plausible range, never equality.
SHAPE_ONLY = {
    "cpu_percent", "collected_at", "top_processes", "system.load_avg",
    "sensors.cpu_power_w", "sensors.gpu_power_w", "sensors.ane_power_w",
    "sensors.system_power_w", "sensors.cpu_temp_c", "sensors.gpu_temp_c",
    "sensors.fan_rpm",
}


def load_python_snapshot() -> dict:
    sys.path.insert(0, str(REPO / "helper"))
    import machine_collector  # noqa: E402
    try:
        import sensor_bridge  # noqa: E402
        sensors = sensor_bridge.read_sensors()
    except Exception:
        sensors = None
    snap = machine_collector.collect_machine_snapshot(sensors=sensors)
    return machine_collector.machine_snapshot_dict(snap)


def load_swift_snapshot(binary: Path) -> dict:
    proc = subprocess.run([str(binary), "machine-snapshot"],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise SystemExit(f"swift helper failed ({proc.returncode}): {proc.stderr[:400]}")
    return json.loads(proc.stdout)


def type_name(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "list"
    if isinstance(v, dict):
        return "dict"
    return type(v).__name__


def numeric(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def compare(py: dict, sw: dict) -> list[str]:
    problems: list[str] = []

    def key_sets(path: str, a: dict, b: dict) -> None:
        """Key-set equality is the cheapest and strongest invariant here — it
        catches every shape bug, which is the class the client cannot detect."""
        only_py = sorted(set(a) - set(b))
        only_sw = sorted(set(b) - set(a))
        if only_py:
            problems.append(f"{path}: keys only in Python: {only_py}")
        if only_sw:
            problems.append(f"{path}: keys only in Swift:  {only_sw}")

    def walk(path: str, a, b) -> None:
        label = path or "<root>"

        if path in SHAPE_ONLY:
            if type_name(a) != type_name(b):
                # int vs float is a real divergence for the client's `d()`
                # coercion only in aggregate, but a str-vs-int is fatal.
                if not (numeric(a) and numeric(b)):
                    problems.append(f"{label}: type {type_name(a)} (py) vs {type_name(b)} (swift)")
            return

        if isinstance(a, dict) and isinstance(b, dict):
            key_sets(label, a, b)
            for k in sorted(set(a) & set(b)):
                walk(f"{path}.{k}" if path else k, a[k], b[k])
            return

        if type_name(a) != type_name(b):
            # null-vs-value is the one that silently zeroes a card.
            if not (numeric(a) and numeric(b)):
                problems.append(
                    f"{label}: type {type_name(a)} (py) vs {type_name(b)} (swift) "
                    f"— py={a!r} swift={b!r}"
                )
                return

        if path in SLOW_DRIFT:
            tol = SLOW_DRIFT[path]
            if tol is None or a is None or b is None:
                return
            if numeric(a) and numeric(b) and abs(a - b) > tol:
                problems.append(f"{label}: {a} (py) vs {b} (swift) — drift > {tol}")
            return

        if isinstance(a, list) and isinstance(b, list):
            return  # only top_processes, which is SHAPE_ONLY

        if a != b:
            problems.append(f"{label}: {a!r} (py) vs {b!r} (swift)")

    walk("", py, sw)
    return problems


def process_invariants(py: dict, sw: dict) -> list[str]:
    """top_processes is a union, not a top-N, so compare its INVARIANTS."""
    problems: list[str] = []
    pp, sp = py.get("top_processes", []), sw.get("top_processes", [])
    if not sp:
        problems.append("top_processes: Swift returned an empty list")
        return problems

    py_keys = set(pp[0]) if pp else set()
    sw_keys = set(sp[0]) if sp else set()
    if py_keys != sw_keys:
        problems.append(f"top_processes[] keys: py={sorted(py_keys)} swift={sorted(sw_keys)}")

    # The union of top-25-by-cpu, top-25-by-mem and every same-UID stopped
    # process is normally well above 25 rows on a real machine. A result capped
    # at exactly the limit is the signature of a naive "top N" port, which is
    # the bug that loses a suspended process on the next refresh.
    if len(sp) <= 25:
        problems.append(
            f"top_processes: only {len(sp)} rows — expected the union (>25); "
            "looks capped at the limit"
        )

    overlap = len({p["pid"] for p in pp} & {p["pid"] for p in sp})
    if pp and overlap < min(len(pp), len(sp)) * 0.5:
        problems.append(
            f"top_processes: only {overlap} shared pids of py={len(pp)}/swift={len(sp)} "
            "— more churn than two calls a second apart should produce"
        )
    return problems


# Divergences that are decisions, not defects. Each must say WHY, and each must
# still be REPORTED — silencing one without printing it is how the next real
# drift hides behind it.
EXPECTED = {
    "capability: keys only in Python: ['kill_process', 'suspend_process']":
        "deliberate: the Swift helper implements neither kill_process nor "
        "signal_process, and MachineControlGate treats an absent capability key "
        "as 'hide the affordance'. Advertising them would put End/Suspend "
        "buttons on a DEVID build that fail with unknown_method. Remove this "
        "entry if those verbs are ever ported.",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--swift-binary", type=Path, default=DEFAULT_SWIFT_BIN)
    args = ap.parse_args()

    if not args.swift_binary.exists():
        raise SystemExit(f"swift helper not built: {args.swift_binary}")

    sw = load_swift_snapshot(args.swift_binary)
    py = load_python_snapshot()

    problems = compare(py, sw) + process_invariants(py, sw)

    print(f"python: {len(py)} top-level keys, {len(py.get('top_processes', []))} processes")
    print(f"swift : {len(sw)} top-level keys, {len(sw.get('top_processes', []))} processes")
    print()

    expected = [p for p in problems if p in EXPECTED]
    unexpected = [p for p in problems if p not in EXPECTED]

    for p in expected:
        print(f"≡ expected: {p}")
        print(f"    {EXPECTED[p]}")
    if expected:
        print()

    if unexpected:
        print(f"✗ {len(unexpected)} unexpected divergence(s):")
        for p in unexpected:
            print(f"    {p}")
        return 1

    print("✓ snapshots agree on key sets, types, and every stable value")
    return 0


if __name__ == "__main__":
    sys.exit(main())
