#!/usr/bin/env python3
"""Read old/new Verbatim Voice JSONL and report S0 user-path latency."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def percentile(values: list[float], probability: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(probability * len(ordered)) - 1)
    return ordered[index]


def metric(record: dict, start: str, end: str) -> float | None:
    timeline = record.get("timeline") or {}
    marks = timeline.get("marks") or []
    offsets = {mark.get("event"): mark.get("offsetNanoseconds") for mark in marks}
    if start not in offsets or end not in offsets:
        return None
    delta = offsets[end] - offsets[start]
    return delta / 1_000_000 if delta >= 0 else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "history",
        nargs="?",
        type=Path,
        default=Path.home() / "Library/Application Support/VerbatimVoice/history.jsonl",
    )
    args = parser.parse_args()
    if not args.history.exists():
        raise SystemExit(f"history not found: {args.history}")

    records: list[dict] = []
    for raw in args.history.read_text(encoding="utf-8").splitlines():
        try:
            records.append(json.loads(raw))
        except json.JSONDecodeError:
            continue

    specs = {
        "trigger_to_waveform": ("trigger", "overlayPresented"),
        "stop_to_dispatch": ("stopRequested", "unicodeDispatched"),
        "dispatch_to_idle": ("unicodeDispatched", "userPathFinished"),
        "user_to_persistence": ("userPathFinished", "persistenceFinished"),
    }
    print(f"records={len(records)} timeline_records={sum(bool(r.get('timeline')) for r in records)}")
    for name, (start, end) in specs.items():
        values = [value for record in records if (value := metric(record, start, end)) is not None]
        if not values:
            print(f"{name}: n=0")
            continue
        print(
            f"{name}: n={len(values)} "
            f"p50={percentile(values, 0.50):.0f}ms "
            f"p90={percentile(values, 0.90):.0f}ms "
            f"p95={percentile(values, 0.95):.0f}ms "
            f"max={max(values):.0f}ms"
        )
    reasons: dict[str, int] = {}
    for record in records:
        reason = record.get("selectedReason")
        if reason:
            reasons[reason] = reasons.get(reason, 0) + 1
    print("selected_reasons=" + json.dumps(reasons, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
