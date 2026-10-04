#!/usr/bin/env python3
"""Inspect Totype JSONL history without third-party dependencies."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


def read_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except json.JSONDecodeError as exc:
                print(f"warning: line {line_number} is invalid JSON: {exc}", file=sys.stderr)
                continue
            if isinstance(value, dict):
                records.append(value)
    return records


def text_of(provider: Any) -> str:
    if not isinstance(provider, dict):
        return ""
    return str(provider.get("text") or "").strip()


def int_values(records: Iterable[dict[str, Any]], provider_key: str, field: str) -> list[int]:
    values: list[int] = []
    for record in records:
        provider = record.get(provider_key)
        if not isinstance(provider, dict):
            continue
        value = provider.get(field)
        if isinstance(value, int):
            values.append(value)
    return values


def percentile(values: list[int], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    index = (len(ordered) - 1) * p
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = index - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def format_latency(values: list[int]) -> str:
    if not values:
        return "no data"
    return (
        f"n={len(values)}, median={statistics.median(values):.0f} ms, "
        f"p95={percentile(values, 0.95):.0f} ms"
    )


def disagreements(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for record in records:
        primary = text_of(record.get("primary"))
        apple = text_of(record.get("appleBaseline"))
        if primary and apple and primary != apple:
            output.append(record)
    return output


def write_tsv(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow([
            "id",
            "started_at",
            "application",
            "soniox",
            "apple",
            "inserted_text",
            "audio_relative_path",
        ])
        for record in records:
            writer.writerow([
                record.get("id", ""),
                record.get("startedAt", ""),
                record.get("targetApplicationName", ""),
                text_of(record.get("primary")),
                text_of(record.get("appleBaseline")),
                record.get("insertedText", ""),
                record.get("audioRelativePath", ""),
            ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("history", type=Path, help="path to history.jsonl")
    parser.add_argument("--disagreements-tsv", type=Path)
    parser.add_argument("--show", type=int, default=8, help="number of disagreements to print")
    args = parser.parse_args()

    if not args.history.exists():
        print(f"history file not found: {args.history}", file=sys.stderr)
        return 2

    records = read_records(args.history)
    statuses = Counter(str(record.get("insertionStatus") or "unknown") for record in records)
    apps = Counter(str(record.get("targetApplicationName") or "unknown") for record in records)
    primary_present = sum(bool(text_of(record.get("primary"))) for record in records)
    apple_present = sum(bool(text_of(record.get("appleBaseline"))) for record in records)
    different = disagreements(records)

    print(f"sessions: {len(records)}")
    print("insertion status:", ", ".join(f"{key}={value}" for key, value in statuses.most_common()) or "none")
    print("top applications:", ", ".join(f"{key}={value}" for key, value in apps.most_common(8)) or "none")
    print(f"Soniox text present: {primary_present}/{len(records)}")
    print(f"Apple baseline present: {apple_present}/{len(records)}")
    print(f"provider disagreements: {len(different)}")
    print("Soniox first partial:", format_latency(int_values(records, "primary", "firstPartialLatencyMilliseconds")))
    print("Soniox finalize:", format_latency(int_values(records, "primary", "finalizeLatencyMilliseconds")))
    print("Apple first partial:", format_latency(int_values(records, "appleBaseline", "firstPartialLatencyMilliseconds")))
    print("Apple finalize:", format_latency(int_values(records, "appleBaseline", "finalizeLatencyMilliseconds")))

    if different:
        print("\nrecent disagreements:")
        for record in different[-max(0, args.show):]:
            print("-", record.get("startedAt", ""), "·", record.get("targetApplicationName", "unknown"))
            print("  Soniox:", text_of(record.get("primary")))
            print("  Apple :", text_of(record.get("appleBaseline")))
            print("  Audio :", record.get("audioRelativePath", "not saved"))

    if args.disagreements_tsv:
        write_tsv(args.disagreements_tsv, different)
        print(f"\nwrote: {args.disagreements_tsv}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
