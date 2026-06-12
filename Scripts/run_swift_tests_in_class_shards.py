#!/usr/bin/env python3
"""Run SwiftPM XCTest classes serially in bounded fresh-process shards.

A single long-lived XCTest process can retain AppKit animations and asynchronous
service tasks created by earlier app tests. On lower-core CI runners that can
starve later XCTest invocations indefinitely. Class shards preserve SwiftPM's
current deterministic class ordering while bounding process-wide test state.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections.abc import Sequence


def listed_test_classes() -> list[str]:
    result = subprocess.run(
        ["swift", "test", "list"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    classes: list[str] = []
    seen: set[str] = set()
    for raw_line in result.stdout.splitlines():
        test_id = raw_line.strip()
        if not test_id or "/" not in test_id:
            continue
        suite_id = test_id.rsplit("/", 1)[0]
        if suite_id and suite_id not in seen:
            seen.add(suite_id)
            classes.append(suite_id)
    if not classes:
        raise RuntimeError("swift test list returned no XCTest classes")
    return classes


def chunks(values: Sequence[str], size: int) -> list[list[str]]:
    return [list(values[offset : offset + size]) for offset in range(0, len(values), size)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--classes-per-shard",
        type=int,
        default=10,
        help="Maximum XCTest classes per fresh test process (default: 10)",
    )
    args = parser.parse_args()
    if args.classes_per_shard < 1:
        parser.error("--classes-per-shard must be positive")

    classes = listed_test_classes()
    shards = chunks(classes, args.classes_per_shard)
    print(f"Running {len(classes)} XCTest classes in {len(shards)} serial shards", flush=True)

    for index, shard in enumerate(shards, start=1):
        class_filter = "|".join(rf"^{re.escape(suite_id)}/" for suite_id in shard)
        first_class = shard[0].rsplit(".", 1)[-1]
        last_class = shard[-1].rsplit(".", 1)[-1]
        print(
            f"Shard {index}/{len(shards)}: {first_class} ... {last_class} "
            f"({len(shard)} classes)",
            flush=True,
        )
        subprocess.run(
            ["swift", "test", "--skip-build", "--filter", class_filter],
            check=True,
        )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"test shard command failed with exit code {error.returncode}", file=sys.stderr)
        raise SystemExit(error.returncode)
