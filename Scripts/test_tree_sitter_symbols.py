#!/usr/bin/env python3
"""Parser and contract tests for linked Tree-sitter symbol verification."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

import verify_tree_sitter_symbols as verifier

from verify_tree_sitter_symbols import (
    REQUIRED_TREE_SITTER_SYMBOL_SET,
    normalized_symbol,
    parse_defined_global_symbols,
    validation_errors,
)


FIXTURES = Path(__file__).parent / "Fixtures" / "tree-sitter-symbols"


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class TreeSitterSymbolVerifierTests(unittest.TestCase):
    def test_valid_exact_fixture_has_every_symbol_once(self) -> None:
        counts = parse_defined_global_symbols(fixture("valid.nm"))
        self.assertEqual(set(counts), REQUIRED_TREE_SITTER_SYMBOL_SET)
        self.assertTrue(all(count == 1 for count in counts.values()))
        self.assertEqual(validation_errors(counts, "exact", label="app", architecture="arm64"), [])

    def test_missing_symbol_fails(self) -> None:
        errors = validation_errors(
            parse_defined_global_symbols(fixture("missing.nm")),
            "exact",
            label="headless",
            architecture="x86_64",
        )
        self.assertTrue(any("tree_sitter_tsx" in error and "missing" in error for error in errors))

    def test_duplicate_symbol_fails(self) -> None:
        errors = validation_errors(
            parse_defined_global_symbols(fixture("duplicate.nm")),
            "exact",
            label="app",
            architecture="arm64",
        )
        self.assertTrue(any("tree_sitter_c" in error and "unique" in error for error in errors))

    def test_undefined_symbol_does_not_count_as_definition(self) -> None:
        counts = parse_defined_global_symbols(fixture("undefined.nm"))
        self.assertNotIn("tree_sitter_c", counts)
        errors = validation_errors(counts, "exact", label="app", architecture="arm64")
        self.assertTrue(any("tree_sitter_c" in error and "missing" in error for error in errors))

    def test_proxy_requires_complete_absence(self) -> None:
        empty_counts = parse_defined_global_symbols(fixture("proxy-empty.nm"))
        self.assertEqual(validation_errors(empty_counts, "absent", label="proxy", architecture="arm64"), [])
        errors = validation_errors(
            parse_defined_global_symbols(fixture("valid.nm")),
            "absent",
            label="proxy",
            architecture="arm64",
        )
        self.assertTrue(any("must export no" in error for error in errors))

    def test_additional_scanner_exports_do_not_change_entrypoint_contract(self) -> None:
        errors = validation_errors(
            parse_defined_global_symbols(fixture("additional-scanner.nm")),
            "exact",
            label="headless",
            architecture="arm64",
        )
        self.assertEqual(errors, [])

    def test_unexpected_parser_entrypoint_fails_exact_and_absent_contracts(self) -> None:
        counts = parse_defined_global_symbols(fixture("extra-parser.nm"))
        exact_errors = validation_errors(counts, "exact", label="app", architecture="arm64")
        self.assertTrue(any("tree_sitter_zig" in error and "unexpected" in error for error in exact_errors))

        absent_errors = validation_errors(
            {"tree_sitter_zig": 1},
            "absent",
            label="proxy",
            architecture="arm64",
        )
        self.assertTrue(any("tree_sitter_zig" in error and "no Tree-sitter parser" in error for error in absent_errors))

    def test_normalizes_only_one_macho_leading_underscore(self) -> None:
        self.assertEqual(normalized_symbol("_tree_sitter_swift"), "tree_sitter_swift")
        self.assertEqual(normalized_symbol("tree_sitter_swift"), "tree_sitter_swift")
        self.assertEqual(normalized_symbol("__tree_sitter_swift"), "_tree_sitter_swift")

    def test_universal_binary_validates_every_architecture_independently(self) -> None:
        with mock.patch.object(
            verifier,
            "nm_output_by_architecture",
            return_value=[("arm64", fixture("valid.nm")), ("x86_64", fixture("valid.nm"))],
        ):
            verifier.verify_binary(
                Path(__file__),
                "exact",
                label="universal fixture",
                lipo="unused-lipo",
                nm="unused-nm",
            )


if __name__ == "__main__":
    unittest.main()
