#!/usr/bin/env python3
"""Focused offline tests for Item 0 security inventory tooling."""

from __future__ import annotations

import ast
import copy
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
MODULE_PATH = SCRIPT_DIR / "inventory_local_signing_identities.py"
FIXTURE_DIR = SCRIPT_DIR / "Fixtures"
IDENTITY_FIXTURE_PATH = FIXTURE_DIR / "item0_identity_inventory_input.json"
MEASUREMENT_RECORD_PATH = FIXTURE_DIR / "item0_measurement_record.json"
SPEC = importlib.util.spec_from_file_location("identity_inventory", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
identity_inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identity_inventory)

CERTIFICATE_NAME = identity_inventory.DEFAULT_CERTIFICATE_NAME
SHA1_A = "A" * 40
SHA1_B = "B" * 40
SHA1_C = "C" * 40


class SecurityInventoryTests(unittest.TestCase):
    def test_identity_parser_filters_exact_name_and_preserves_diagnostics(self) -> None:
        output = f'''\
  1) {SHA1_A} "{CERTIFICATE_NAME}"
  2) {SHA1_B} "{CERTIFICATE_NAME}" (CSSMERR_TP_CERT_EXPIRED)
  3) {SHA1_C} "Different Name"
  1) {SHA1_A} "{CERTIFICATE_NAME}"
     1 valid identities found
'''

        self.assertEqual(
            identity_inventory.parse_identity_output(output, CERTIFICATE_NAME),
            [
                {"sha1": SHA1_A, "name": CERTIFICATE_NAME, "diagnostic": None},
                {"sha1": SHA1_B, "name": CERTIFICATE_NAME, "diagnostic": "CSSMERR_TP_CERT_EXPIRED"},
            ],
        )

    def test_offline_fixture_classifies_duplicates_expiry_and_certificates_without_keys(self) -> None:
        fixture = json.loads(IDENTITY_FIXTURE_PATH.read_text(encoding="utf-8"))
        inventory = identity_inventory.collect_inventory(
            fixture,
            now=identity_inventory.parse_iso_datetime(fixture["evaluated_at"]),
        )

        self.assertEqual(inventory["source"], "offline-fixture")
        self.assertEqual(
            inventory["summary"],
            {
                "exact_name_certificate_count": 3,
                "private_key_backed_identity_count": 2,
                "valid_private_key_backed_identity_count": 1,
                "certificate_without_private_key_count": 1,
                "duplicate_certificate_count": 2,
                "distinct_sha1_count": 3,
                "unmatched_identity_count": 0,
            },
        )
        self.assertEqual([certificate["validity"] for certificate in inventory["certificates"]], ["valid", "expired", "valid"])
        self.assertEqual([certificate["private_key_backed"] for certificate in inventory["certificates"]], [True, True, False])
        self.assertEqual([certificate["valid_code_signing_identity"] for certificate in inventory["certificates"]], [True, False, False])

    def test_inconsistent_identity_capture_is_rejected(self) -> None:
        fixture = json.loads(IDENTITY_FIXTURE_PATH.read_text(encoding="utf-8"))
        inconsistent = copy.deepcopy(fixture)
        inconsistent["valid_identity_output"] += f'  2) {SHA1_C} "{CERTIFICATE_NAME}"\n'

        with self.assertRaisesRegex(ValueError, "Valid identities missing from all identities"):
            identity_inventory.collect_inventory(
                inconsistent,
                now=identity_inventory.parse_iso_datetime(inconsistent["evaluated_at"]),
            )

    def test_inventory_implementation_is_offline_by_construction(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        syntax_tree = ast.parse(source)
        imported_modules = {
            alias.name
            for node in ast.walk(syntax_tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        imported_modules.update(
            node.module
            for node in ast.walk(syntax_tree)
            if isinstance(node, ast.ImportFrom) and node.module is not None
        )
        self.assertEqual(
            imported_modules,
            {"__future__", "argparse", "datetime", "json", "pathlib", "re", "typing"},
        )

        forbidden_fragments = [
            "import subprocess",
            "subprocess.",
            "SecItem",
            "SecKeychain",
            '"security"',
            "default-keychain",
            "find-identity",
            "find-certificate",
        ]
        for fragment in forbidden_fragments:
            self.assertNotIn(fragment, source, fragment)

        self.assertFalse((SCRIPT_DIR / "measure_keychain_access.swift").exists())

    def test_makefile_validation_path_runs_only_the_offline_inventory_test(self) -> None:
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        inventory_recipe_lines = [
            line.strip()
            for line in makefile.splitlines()
            if "test_security_inventory.py" in line
        ]
        self.assertEqual(inventory_recipe_lines, ["python3 Scripts/test_security_inventory.py"])
        self.assertNotIn("measure_keychain_access", makefile)
        self.assertNotIn("inventory_local_signing_identities.py --", makefile)

    def test_item0_measurement_record_preserves_passes_and_unlocks_item8(self) -> None:
        record = json.loads(MEASUREMENT_RECORD_PATH.read_text(encoding="utf-8"))
        statuses = {
            (entry["architecture"], entry["product"]): entry["status"]
            for entry in record["architecture_probes"]
        }

        self.assertEqual(statuses[("arm64", "RepoPrompt")], "pass")
        self.assertEqual(statuses[("arm64", "repoprompt-mcp")], "pass")
        self.assertEqual(statuses[("x86_64", "repoprompt-mcp")], "pass")
        self.assertEqual(statuses[("x86_64", "RepoPrompt")], "pass")
        self.assertEqual(record["item0_status"]["status"], "incomplete")
        self.assertEqual(record["item8_gate"]["status"], "pass")
        self.assertFalse(record["keychain_access_measurement"]["startup_scan_approved"])
        self.assertTrue(record["safety_constraints"]["x86_64_repoprompt_probe_rerun_during_completion"])


if __name__ == "__main__":
    unittest.main()
