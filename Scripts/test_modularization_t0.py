#!/usr/bin/env python3
"""T0 move-audit, access-lift, and test-import tests in isolated Git fixtures."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import modularization_access_lift as access  # noqa: E402
import modularization_move_audit as audit  # noqa: E402
import modularization_retarget_test_imports as retarget  # noqa: E402


def write(root: Path, name: str, text: str) -> None:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=root, check=True, stdout=subprocess.DEVNULL)


class GitFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "Test")
        write(self.root, "Package.swift", '.target(name: "NewModule"),\n')
        write(self.root, "Sources/OldModule/Thing.swift", "internal struct Thing {\n    let value = 1\n}\n")
        write(self.root, "Sources/OldModule/Client.swift", "import OldModule\ninternal func client() {}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "base")

    def commit(self) -> dict:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "head")
        return audit.audit("HEAD^", "HEAD", self.root)

    def test_r100_move_and_json_manifest(self) -> None:
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        (self.root / "Sources/OldModule/Thing.swift").rename(target)
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["moves"][0]["similarity"], 100)
        self.assertIn("manifest", json.loads(json.dumps(report)))

    def test_access_only_move_pairs_delete_and_add(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "package struct Thing {\n    let value = 1\n}\n")
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["moves"][0]["base_sha256"], report["moves"][0]["head_sha256"])

    def test_body_and_whitespace_changes_fail(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "package struct Thing {\n    let value = 2\n}\n")
        self.assertTrue(self.commit()["violations"])

    def test_modified_client_access_and_first_party_import_only(self) -> None:
        write(self.root, "Sources/OldModule/Client.swift", "import NewModule\npackage func client() {}\n")
        self.assertEqual(self.commit()["violations"], [])

    def test_modified_client_body_and_external_import_fail(self) -> None:
        write(self.root, "Sources/OldModule/Client.swift", "import Foundation\npackage func client() { print(1) }\n")
        self.assertTrue(self.commit()["violations"])

    def test_non_swift_and_discovery_parity(self) -> None:
        write(self.root, "README.md", "changed\n")
        report = self.commit()
        self.assertTrue(report["violations"])
        self.assertTrue(audit.audit("HEAD^", "HEAD", self.root, 10, 11)["violations"])

    def test_import_in_move_must_be_first_party(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "import Foundation\npackage struct Thing {\n    let value = 1\n}\n")
        self.assertTrue(self.commit()["violations"])

    def test_unchanged_external_import_in_move_passes(self) -> None:
        original = self.root / "Sources/OldModule/Thing.swift"
        original.write_text("import Foundation\n" + original.read_text())
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "external import in base")
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        original.rename(target)
        self.assertEqual(self.commit()["violations"], [])

    def test_cli_exit_and_json(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").rename(self.root / "Sources/OldModule/Other.swift")
        self.commit()
        destination = self.root / "report.json"
        result = subprocess.run([sys.executable, str(SCRIPT_DIR / "modularization_move_audit.py"),
                                 "--base", "HEAD^", "--json", str(destination), "--tests-before", "2",
                                 "--tests-after", "2"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(destination.read_text())["violations"], [])

    def test_f1_modified_multiline_string_is_not_an_access_change(self) -> None:
        path = "Sources/OldModule/Client.swift"
        write(self.root, path, 'let text = """\npublic struct Thing {}\n"""\n')
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "string base")
        write(self.root, path, 'let text = """\npackage struct Thing {}\n"""\n')
        self.assertTrue(self.commit()["violations"])

    def test_f1_moved_multiline_string_and_import_text_fail(self) -> None:
        path = self.root / "Sources/OldModule/Thing.swift"
        path.write_text('let text = """\nimport OldModule\npublic struct Thing {}\n"""\n')
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "string base")
        path.unlink()
        write(self.root, "Sources/NewModule/Thing.swift",
              'let text = """\nimport NewModule\npackage struct Thing {}\n"""\n')
        self.assertTrue(self.commit()["violations"])

    def test_f1_import_text_inside_raw_string_is_not_dropped(self) -> None:
        path = "Sources/OldModule/Client.swift"
        write(self.root, path, 'let text = #"""\nimport OldModule\n"""#\n')
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "raw string base")
        write(self.root, path, 'let text = #"""\nimport NewModule\n"""#\n')
        self.assertTrue(self.commit()["violations"])

    def test_f2_diverged_base_uses_merge_base_blobs(self) -> None:
        git(self.root, "checkout", "-qb", "main-tip")
        write(self.root, "Sources/OldModule/Thing.swift", "internal struct Thing {\n    let value = 2\n}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "main body edit")
        git(self.root, "checkout", "-qb", "topic", "HEAD~1")
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "internal struct Thing {\n    let value = 2\n}\n")
        self.assertTrue(self.commit()["violations"])
        git(self.root, "checkout", "-qb", "pure", "HEAD~1")
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True, exist_ok=True)
        (self.root / "Sources/OldModule/Thing.swift").rename(target)
        self.commit()
        report = audit.audit("main-tip", "HEAD", self.root)
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["comparison_base"], subprocess.check_output(
            ["git", "rev-parse", "HEAD~1"], cwd=self.root, text=True).strip())

    def test_f3_binary_classified_modified_swift_fails_closed(self) -> None:
        path = self.root / "Sources/OldModule/Client.swift"
        path.write_bytes(b"// nul\0\nprint(1)\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "binary base")
        path.write_bytes(b"// nul\0\nprint(2)\n")
        self.assertTrue(self.commit()["violations"])

    def test_f3_disabled_git_diff_still_fails_body_edit(self) -> None:
        write(self.root, ".gitattributes", "*.swift -diff\n")
        write(self.root, "Sources/OldModule/Client.swift", "print(1)\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "diff disabled")
        write(self.root, "Sources/OldModule/Client.swift", "print(2)\n")
        self.assertTrue(self.commit()["violations"])

    def test_f3_byte_identical_binary_r100_move_passes(self) -> None:
        source = self.root / "Sources/OldModule/Thing.swift"
        source.write_bytes(b"\xff\0unchanged")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "binary base")
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        source.rename(target)
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["moves"][0]["hash_kind"], "raw")

    def test_f7_package_manifest_edit_is_allowlisted(self) -> None:
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        (self.root / "Sources/OldModule/Thing.swift").rename(target)
        write(self.root, "Package.swift", '.target(name: "NewModule"),\n.target(name: "Other"),\n')
        self.assertEqual(self.commit()["violations"], [])

    def test_f8_class_method_access_modifier_is_normalized(self) -> None:
        write(self.root, "Sources/OldModule/Thing.swift",
              "package class Thing {\n    class internal func value() -> Int { 1 }\n}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "method base")
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift",
              "package class Thing {\n    class package func value() -> Int { 1 }\n}\n")
        self.assertEqual(self.commit()["violations"], [])

    def test_f9_quoted_unicode_path_is_parsed_as_raw_git_path(self) -> None:
        git(self.root, "config", "core.quotePath", "true")
        names = ("日本.swift", "tab\tfile.swift", "line\nbreak.swift", 'quote"file.swift')
        for name in names:
            write(self.root, f"Sources/OldModule/{name}", "internal struct Japanese {}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "quoted paths base")
        target_dir = self.root / "Sources/NewModule"
        target_dir.mkdir(parents=True)
        for name in names:
            (self.root / "Sources/OldModule" / name).rename(target_dir / name)
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual({move["to"] for move in report["moves"]},
                         {f"Sources/NewModule/{name}" for name in names})


class NormalizationTests(unittest.TestCase):
    def test_access_head_only_and_whitespace_preserved(self) -> None:
        self.assertEqual(audit.normalize_access("@MainActor public struct Thing {}\n"),
                         "@MainActor struct Thing {}\n")
        self.assertEqual(audit.normalize_access("public  struct Thing {}\n"), " struct Thing {}\n")
        self.assertEqual(audit.normalize_access("let text = \"public struct Foo\"\n"),
                         "let text = \"public struct Foo\"\n")

    def test_nested_attribute_and_literal_are_not_normalized_as_code(self) -> None:
        attribute = '@available(*, renamed: "foo(bar:)")'
        before = f'{attribute} internal  struct Foo {{}}\n'
        after = f'{attribute} package  struct Foo {{}}\n'
        self.assertEqual(audit.normalize_access(before), audit.normalize_access(after))
        self.assertEqual(audit.normalized(before.encode()), audit.normalized(after.encode()))
        self.assertEqual(audit.normalize_access('@available(*, message: "public )") struct Foo {}\n'),
                         '@available(*, message: "public )") struct Foo {}\n')
        self.assertNotEqual(audit.normalized(b'internal  struct Foo {}\n'),
                            audit.normalized(b'internal struct Foo {}\n'))


class HelperTests(unittest.TestCase):
    def test_lift_balances_nested_attributes_and_quoted_parentheses(self) -> None:
        cases = (
            '@available(*, renamed: "foo(bar:)") internal struct Foo {}\n',
            '@available(*, message: "close ) now") internal struct Foo {}\n',
            '@available(*, message: "public ) struct Foo") internal struct Foo {}\n',
            '@Some(arg: nested(foo())) internal struct Foo {}\n',
            '@available(*, message: "close \\" ) later") internal struct Foo {}\n',
        )
        for before in cases:
            with self.subTest(before=before):
                expected = before.removesuffix('internal struct Foo {}\n') + 'package struct Foo {}\n'
                self.assertEqual(access.lift_line(before, 'Foo'), expected)
                self.assertEqual(audit.normalized(before.encode()), audit.normalized(expected.encode()))
        self.assertIsNone(access.lift_line('@available(*, message: "unfinished) struct Foo {}\n', 'Foo'))

    def test_lift_preserves_modifier_separator_whitespace(self) -> None:
        for separator in (' ', '  ', '\t', '\t\t', ' \t '):
            before = f'internal{separator}struct Foo {{}}\n'
            after = f'package{separator}struct Foo {{}}\n'
            with self.subTest(separator=repr(separator)):
                self.assertEqual(access.lift_line(before, 'Foo'), after)
                self.assertEqual(audit.normalized(before.encode()), audit.normalized(after.encode()))

    def test_access_lift_unique_cross_module_and_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Thing.swift", "@MainActor internal struct Thing {}\n")
            write(root, "Sources/Two/Client.swift", "let thing = Thing()\n")
            log = (f"{root}/Sources/Two/Client.swift:1:13: error: 'Thing' is inaccessible due to 'internal' protection level\n"
                   f"{root}/Sources/One/Thing.swift:1:21: note: 'Thing' declared here\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(notes, [])
            self.assertEqual(changes[root / "Sources/One/Thing.swift"], "@MainActor package struct Thing {}\n")
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "@MainActor internal struct Thing {}\n")

    def test_access_lift_missing_scope_without_declaration_note_skips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Foo.swift", "struct Foo {}\n")
            write(root, "Sources/Three/Foo.swift", "struct Foo {}\n")
            write(root, "Sources/Two/Client.swift", "let value = Foo()\n")
            changes, notes = access.proposals("Sources/Two/Client.swift:1:13: error: cannot find 'Foo' in scope\n", root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)
            (root / "Sources/Three/Foo.swift").unlink()
            changes, notes = access.proposals("Sources/Two/Client.swift:1:13: error: cannot find 'Foo' in scope\n", root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)

    def test_access_cli_dry_run_then_apply_in_git_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            write(root, "Sources/One/Thing.swift", "internal struct Thing {}\n")
            write(root, "Sources/Two/Client.swift", "let value = Thing()\n")
            git(root, "add", ".")
            git(root, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "-qm", "base")
            log = root / "build.log"
            log.write_text("Sources/Two/Client.swift:1:13: error: 'Thing' is inaccessible due to 'internal' protection level\n"
                           "Sources/One/Thing.swift:1:17: note: 'Thing' declared here\n")
            command = [sys.executable, str(SCRIPT_DIR / "modularization_access_lift.py"), str(log), "--root", str(root)]
            dry = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("+package struct Thing", dry.stdout)
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "internal struct Thing {}\n")
            applied = subprocess.run(command + ["--apply"], cwd=root, capture_output=True, text=True)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "package struct Thing {}\n")

    def test_lift_then_move_audit_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, 'init', '-q')
            git(root, 'config', 'user.email', 'test@example.invalid')
            git(root, 'config', 'user.name', 'Test')
            old_path = root / 'Sources/One/Foo.swift'
            before = '@available(*, renamed: "foo(bar:)") internal\t\tstruct Foo {}\n'
            write(root, 'Sources/One/Foo.swift', before)
            write(root, 'Sources/Two/Client.swift', 'let value = Foo()\n')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'base')
            log = ("Sources/Two/Client.swift:1:13: error: 'Foo' is inaccessible due to 'internal' protection level\n"
                   "Sources/One/Foo.swift:1:51: note: 'Foo' declared here\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(notes, [])
            old_path.unlink()
            new_path = root / 'Sources/Two/Foo.swift'
            new_path.write_text(changes[old_path])
            git(root, 'add', '-A')
            git(root, 'commit', '-qm', 'moved')
            report = audit.audit('HEAD^', 'HEAD', root)
            self.assertEqual(report['violations'], [])
            self.assertEqual(report['moves'][0]['base_sha256'], report['moves'][0]['head_sha256'])

    def test_retarget_cli_dry_run_then_apply_in_git_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            write(root, "Sources/NewModule/Thing.swift", "struct Thing {}\n")
            write(root, "Tests/AppTests/ThingTests.swift", "@testable import RepoPromptApp\n")
            git(root, "add", ".")
            git(root, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "-qm", "base")
            path = root / "Tests/AppTests/ThingTests.swift"
            command = [sys.executable, str(SCRIPT_DIR / "modularization_retarget_test_imports.py"),
                       "--module", "NewModule", str(path)]
            dry = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("+@testable import NewModule", dry.stdout)
            self.assertEqual(path.read_text(), "@testable import RepoPromptApp\n")
            applied = subprocess.run(command + ["--apply"], cwd=root, capture_output=True, text=True)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual(path.read_text(), "@testable import NewModule\n")

    def test_test_import_retarget(self) -> None:
        before = "@testable import RepoPromptApp\nimport Foundation\n// @testable import RepoPromptApp\n"
        after = retarget.retarget(before, "NewModule")
        self.assertIn("@testable import NewModule\n", after)
        self.assertIn("// @testable import RepoPromptApp", after)

    def test_f4_access_lift_refuses_literal_and_comment_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Thing.swift", 'let text = """\ninternal struct Thing {}\n"""\n')
            write(root, "Sources/Two/Client.swift", "let value = Thing()\n")
            log = ("Sources/Two/Client.swift:1:13: error: 'Thing' is inaccessible due to 'internal' protection level\n"
                   "Sources/One/Thing.swift:2:17: note: 'Thing' declared here\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)
            write(root, "Sources/One/Thing.swift", "// internal struct Thing {}\n")
            changes, notes = access.proposals(log.replace(":2:17:", ":1:17:"), root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)
            write(root, "Sources/One/Thing.swift", "/*\ninternal struct Thing {}\n*/\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)

    def test_f5_access_lift_refuses_unproven_provider_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Service.swift", "struct Service {\ninternal func\nsecret() {}\n}\n")
            write(root, "Sources/Unrelated/Other.swift", "struct Other {\ninternal func secret() {}\n}\n")
            write(root, "Sources/Client/Use.swift", "Service().secret()\n")
            log = ("Sources/Client/Use.swift:1:11: error: 'secret' is inaccessible due to 'internal' protection level\n"
                   "One.Service.secret:2:15: note: 'secret()' declared here\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(changes, {})
            self.assertIn("requires one exact first-party declaration note", notes[0])

    def test_f6_access_lift_refuses_implicit_or_enclosing_access(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Thing.swift",
                  "public struct Thing {}\npublic extension Thing {\n    func thing() -> Int { 1 }\n}\n")
            write(root, "Sources/Client/Use.swift", "thing()\n")
            log = ("Sources/Client/Use.swift:1:1: error: cannot find 'thing' in scope\n"
                   "Sources/One/Thing.swift:3:10: note: 'thing' declared here\n")
            changes, notes = access.proposals(log, root)
            self.assertEqual(changes, {})
            self.assertIn("not explicitly internal", notes[0])
            write(root, "Sources/One/Thing.swift", "private\nfunc thing() {}\n")
            changes, notes = access.proposals(log.replace(":3:10:", ":2:6:"), root)
            self.assertEqual(changes, {})
            self.assertIn("not explicitly internal", notes[0])

    def test_f10_retarget_changes_only_real_import_lines(self) -> None:
        before = ('@testable import RepoPromptApp\n'
                  'let fixture = """\n@testable import RepoPromptApp\n"""\n'
                  '/*\n@testable import RepoPromptApp\n*/\n'
                  'let raw = #"""\n@testable import RepoPromptApp\n"""#\n')
        after = retarget.retarget(before, "NewModule")
        self.assertEqual(after.count("@testable import NewModule"), 1)
        self.assertEqual(after.count("@testable import RepoPromptApp"), 3)


if __name__ == "__main__":
    unittest.main()
