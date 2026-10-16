#!/usr/bin/env python3
"""Route local test filters to their app-free owning target when unambiguous."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from modularization_test_target import resolve

ROOT = Path(__file__).resolve().parent.parent


def command(module: str | None, filter_value: str | None, test_product: str | None) -> list[str]:
    if module and test_product:
        raise ValueError('MODULE and TEST_PRODUCT cannot be combined')
    if not module and filter_value and not test_product:
        module = resolve(ROOT, filter_value)
    result = [str(ROOT / 'conductor'), 'test']
    if module:
        result += ['--module', module]
    if filter_value:
        result += ['--filter', filter_value]
    if test_product:
        result += ['--test-product', test_product]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module')
    parser.add_argument('--filter')
    parser.add_argument('--test-product')
    args = parser.parse_args()
    try:
        return subprocess.call(command(args.module, args.filter, args.test_product), cwd=ROOT)
    except ValueError as error:
        print(f'dev-test: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
