#!/usr/bin/env python3
"""Catalog, placement, test routing, affected-target, and CI-gate unit tests."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import modularization_affected_tests as affected  # noqa: E402
import modularization_ci_build as ci_build  # noqa: E402
import modularization_ci_artifact as artifact  # noqa: E402
import modularization_modules as modules  # noqa: E402
import modularization_test_target as target  # noqa: E402
import generate_xcode_workspace as xcode_workspace  # noqa: E402
import swift_imports  # noqa: E402
import conductor  # noqa: E402


def fixture(root: Path) -> tuple[dict, dict]:
    rows = {
        'RepoPromptApp': {'source_root': 'Sources/RepoPrompt', 'allowed_dependencies': ['Core'],
                          'test_target': 'RepoPromptTests'},
        'Core': {'source_root': 'Sources/Core', 'allowed_dependencies': [],
                 'test_target': 'CoreTests', 'app_free_tests': True},
        'CoreTests': {'source_root': 'Tests/CoreTests', 'allowed_dependencies': ['Core']},
        'RepoPromptTests': {'source_root': 'Tests/RepoPromptTests', 'allowed_dependencies': ['RepoPromptApp']},
    }
    catalog = {'modules': rows, 'moved_families': {'Core': {
        'owner': 'Core', 'former_app_roots': ['Sources/RepoPrompt/Infrastructure/Core'],
        'former_app_files': ['Sources/RepoPrompt/Infrastructure/OldCore.swift'],
    }}}
    package = {'targets': [{'name': name, 'path': row['source_root'],
                            'dependencies': [{'byName': [dependency]} for dependency in row['allowed_dependencies']]}
                           for name, row in rows.items()]}
    for row in rows.values():
        (root / row['source_root']).mkdir(parents=True, exist_ok=True)
    (root / 'Scripts/modularization').mkdir(parents=True, exist_ok=True)
    (root / 'Scripts/modularization/modules.json').write_text(json.dumps(catalog))
    return package, catalog


class CatalogTests(unittest.TestCase):
    def test_allowed_edges_imports_and_new_file_placement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            (root / 'Sources/Core/Core.swift').write_text('import Foundation\n')
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                self.assertEqual(modules.check(root, package, catalog), [])
                (root / 'Sources/Core/Core.swift').write_text('import RepoPromptApp\n')
                self.assertTrue(any('undeclared first-party import' in error
                                    for error in modules.check(root, package, catalog)))
            with mock.patch.object(modules, 'added_swift_paths', return_value={
                'Sources/RepoPrompt/Infrastructure/Core/New.swift'
            }):
                self.assertTrue(any('new Swift source belongs in Core' in error
                                    for error in modules.check(root, package, catalog)))

    def test_explicit_target_edges_and_actual_app_free_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            targets = {entry['name']: entry for entry in package['targets']}
            targets['CoreTests']['dependencies'].append({'target': ['RepoPromptApp', None]})
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                errors = modules.check(root, package, catalog)
            self.assertTrue(any('CoreTests: direct edges' in error for error in errors), errors)
            self.assertTrue(any('transitively build RepoPromptApp' in error for error in errors), errors)

    def test_conditional_explicit_target_edge_is_not_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            targets = {entry['name']: entry for entry in package['targets']}
            targets['Core']['dependencies'].append({'target': ['RepoPromptApp', {'platforms': ['macos']}]})
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                errors = modules.check(root, package, catalog)
            self.assertTrue(any('Core: direct edges' in error for error in errors), errors)

    def test_unknown_dependency_form_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            package['targets'][0]['dependencies'].append({'futureKind': ['Core', None]})
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                errors = modules.check(root, package, catalog)
            self.assertTrue(any('unrecognized dependency' in error for error in errors), errors)

    def test_owning_test_closure_must_exclude_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            catalog['modules']['CoreTests']['allowed_dependencies'].append('RepoPromptApp')
            next(row for row in package['targets'] if row['name'] == 'CoreTests')['dependencies'].append(
                {'byName': ['RepoPromptApp', None]})
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                self.assertTrue(any('transitively build RepoPromptApp' in error
                                    for error in modules.check(root, package, catalog)))

    def test_xcode_test_dependencies_follow_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            catalog['modules']['RepoPromptTests']['allowed_dependencies'].append('Core')
            (root / 'Scripts/modularization/modules.json').write_text(json.dumps(catalog))
            target_row = next(row for row in package['targets'] if row['name'] == 'RepoPromptTests')
            with self.assertRaisesRegex(xcode_workspace.GeneratorError, 'missing.*Core'):
                xcode_workspace.validate_repo_prompt_test_dependencies(target_row, root)
            target_row['dependencies'].append({'byName': ['Core', None]})
            xcode_workspace.validate_repo_prompt_test_dependencies(target_row, root)
            target_row['dependencies'][-1] = {'target': ['Core', None]}
            xcode_workspace.validate_repo_prompt_test_dependencies(target_row, root)

    def test_import_scanner_covers_swift_attributes_and_access(self) -> None:
        source = ('@preconcurrency import AppKit\n'
                  'public import SwiftUI\n'
                  '@_spi(Private) package import RepoPromptApp\n'
                  '@testable import Core\n'
                  'import class AppKit.NSView\n')
        self.assertEqual(swift_imports.imported_modules(source),
                         ['AppKit', 'SwiftUI', 'RepoPromptApp', 'Core', 'AppKit'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Attributed.swift').write_text(source)
            violations = swift_imports.forbidden_ui_imports([root])
            self.assertEqual(len(violations), 3, violations)

    def test_comment_separated_attributed_ui_imports_fail_cli_gate(self) -> None:
        source = ('@preconcurrency /* imported for legacy declarations */ import AppKit\n'
                  '@_spi(Private) /* outer /* nested */ comment */ public import SwiftUI\n'
                  'package import class AppKit.NSView\n'
                  'import Foundation; @preconcurrency /* sibling */ import AppKit\n')
        self.assertEqual(swift_imports.imported_modules(source),
                         ['AppKit', 'SwiftUI', 'AppKit', 'Foundation', 'AppKit'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'ImportComment.swift').write_text(source)
            result = subprocess.run(
                [sys.executable, str(SCRIPT_DIR / 'swift_imports.py'), '--forbid-ui', str(root)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('ImportComment.swift:1:', result.stdout)
            self.assertIn('ImportComment.swift:2:', result.stdout)
            self.assertIn('ImportComment.swift:3:', result.stdout)
            self.assertIn('ImportComment.swift:4:', result.stdout)

    def test_multiline_comment_between_attribute_and_import(self) -> None:
        source = '@preconcurrency /* legacy\n declarations */ import AppKit\n'
        self.assertEqual(swift_imports.imported_modules(source), ['AppKit'])

    def test_comment_and_string_lookalikes_are_not_imports(self) -> None:
        source = ('// @preconcurrency /* comment */ import AppKit\n'
                  '/* @preconcurrency import SwiftUI */\n'
                  'let example = """\n'
                  '@preconcurrency /* text */ import AppKit\n'
                  '"""\n'
                  'let raw = #"import SwiftUI"#\n'
                  'import Foundation\n')
        self.assertEqual(swift_imports.imported_modules(source), ['Foundation'])

    def test_unterminated_comment_or_string_fails_closed(self) -> None:
        for source in ('@preconcurrency /* unfinished import AppKit',
                       'let value = "unfinished\nimport AppKit'):
            with self.subTest(source=source):
                with self.assertRaises(swift_imports.SwiftImportScanError):
                    swift_imports.imported_modules(source)
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / 'Broken.swift').write_text(source)
                    result = subprocess.run(
                        [sys.executable, str(SCRIPT_DIR / 'swift_imports.py'), '--forbid-ui', str(root)],
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout)
                    self.assertIn('failed closed', result.stderr)

    def test_filter_resolves_only_exact_app_free_suite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, catalog = fixture(root)
            (root / 'Tests/CoreTests/FeatureTests.swift').write_text('final class FeatureTests {}\n')
            (root / 'Tests/RepoPromptTests/AppTests.swift').write_text('final class AppTests {}\n')
            self.assertEqual(target.resolve(root, 'FeatureTests/testOne'), 'CoreTests')
            self.assertIsNone(target.resolve(root, 'FeatureTests/.*|OtherTests/.*'))
            self.assertIsNone(target.resolve(root, 'FeatureTests/test.*'))
            self.assertIsNone(target.resolve(root, 'AppTests'))
            self.assertIsNone(target.resolve(root, 'Feature.*'))
            self.assertEqual(affected.select(root, ['Sources/Core/Core.swift'], catalog), ['CoreTests'])
            self.assertEqual(affected.select(root, ['Package.swift'], catalog), ['CoreTests'])

    def test_conductor_passes_timing_policy_to_ci_child(self) -> None:
        registry = conductor.OperationRegistry(SCRIPT_DIR.parent)
        with mock.patch.dict('os.environ', {'TYPECHECK_RATCHET_ENFORCE': '0'}):
            snapshot = registry.client_env_snapshot()
        self.assertEqual(snapshot['TYPECHECK_RATCHET_ENFORCE'], '0')
        argv, _, _, env, _ = registry.prepare({
            'operation': 'ci-build-tests', 'args': {}, 'env': snapshot,
        })
        self.assertEqual(Path(argv[1]).name, 'modularization_ci_build.py')
        self.assertEqual(env['TYPECHECK_RATCHET_ENFORCE'], '0')

    def test_enforced_ratchet_cleans_before_build(self) -> None:
        class BuildProcess:
            stdout = iter(['Build complete! (0.1s)\n'])

            def wait(self) -> int:
                return 0

        listing = subprocess.CompletedProcess([], 0, stdout='RepoPromptTests.Example/testOne\n')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Package.swift').write_text('// fixture manifest')
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps({'typecheck': {'function_bodies_1000ms': 0,
                                                          'expressions_500ms': 0}}))
            with mock.patch.object(ci_build, 'ROOT', root), mock.patch.object(ci_build, 'BASELINE', baseline), \
                    mock.patch.object(ci_build.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0), listing, subprocess.CompletedProcess([], 0, stdout=json.dumps({'targets': [{'type': 'test', 'name': 'RepoPromptTests'}]}))]) as run, \
                    mock.patch.object(ci_build.subprocess, 'Popen', return_value=BuildProcess()), \
                    mock.patch.object(ci_build, 'sources_import_module', return_value=False), \
                    mock.patch.dict('os.environ', {'TYPECHECK_RATCHET_ENFORCE': '1'}):
                self.assertEqual(ci_build.main(), 0)
                self.assertEqual(run.call_args_list[0].args[0], ['swift', 'package', 'clean'])

    def test_report_only_ratchet_keeps_regressed_diagnostic_visible(self) -> None:
        class BuildProcess:
            stdout = iter(['/checkout/Sources/RepoPrompt/App/X.swift:3:4: warning: expression took 502ms to type-check\n'])

            def wait(self) -> int:
                return 0

        listing = subprocess.CompletedProcess([], 0, stdout='RepoPromptTests.Example/testOne\n')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Package.swift').write_text('// fixture manifest')
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps({'typecheck': {'function_bodies_1000ms': 0,
                                                          'expressions_500ms': 0}}))
            with mock.patch.object(ci_build, 'ROOT', root), mock.patch.object(ci_build, 'BASELINE', baseline), \
                    mock.patch.object(ci_build.subprocess, 'run', side_effect=[listing, subprocess.CompletedProcess([], 0, stdout=json.dumps({'targets': [{'type': 'test', 'name': 'RepoPromptTests'}]}))]) as run, \
                    mock.patch.object(ci_build.subprocess, 'Popen', return_value=BuildProcess()), \
                    mock.patch.object(ci_build, 'sources_import_module', return_value=False), \
                    mock.patch.dict('os.environ', {'TYPECHECK_RATCHET_ENFORCE': '0'}):
                self.assertEqual(ci_build.main(), 0)
                self.assertEqual(run.call_count, 2)

    def test_import_scanner_handles_backticks_multiline_attributes_and_testing(self) -> None:
        source = ('import `AppKit`\n@_spi(\n Private\n) import `Testing`\n'
                  'internal import /* module */ Testing\n'
                  'let fake = "import Testing"\n// import Testing\n')
        self.assertEqual(swift_imports.imported_modules(source), ['AppKit', 'Testing', 'Testing'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Tests').mkdir()
            (root / 'Tests/Imports.swift').write_text(source)
            self.assertTrue(swift_imports.sources_import_module(root / 'Tests', 'Testing'))
            self.assertTrue(artifact.sources_import_module(root / 'Tests', 'Testing'))
            self.assertTrue(swift_imports.forbidden_ui_imports([root / 'Tests']))
            for import_line in ('@preconcurrency import Testing', 'internal import Testing',
                                'import /* module */ Testing', 'import `Testing`'):
                (root / 'Tests/Imports.swift').write_text(import_line + '\n')
                self.assertTrue(swift_imports.sources_import_module(root / 'Tests', 'Testing'))
            (root / 'Tests/Imports.swift').write_text('/* unterminated')
            self.assertTrue(swift_imports.sources_import_module(root / 'Tests', 'Testing'))

    def test_import_scanner_sees_imports_after_utf8_bom(self) -> None:
        self.assertEqual(swift_imports.imported_modules('\ufeffimport AppKit\n'), ['AppKit'])
        self.assertEqual(swift_imports.imported_modules('\ufeff@testable import Testing\n'), ['Testing'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Tests').mkdir()
            (root / 'Tests/Bom.swift').write_text('\ufeffimport Testing\n', encoding='utf-8')
            self.assertTrue(swift_imports.sources_import_module(root / 'Tests', 'Testing'))
            self.assertTrue(artifact.sources_import_module(root / 'Tests', 'Testing'))
            (root / 'Tests/Bom.swift').write_text('\ufeffimport AppKit\n', encoding='utf-8')
            self.assertTrue(swift_imports.forbidden_ui_imports([root / 'Tests']))

    def test_all_module_selection_is_independent_of_incremental_base(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, catalog = fixture(root)
            self.assertEqual(affected.select(root, ['Package.swift'], catalog), ['CoreTests'])
            result = subprocess.run([sys.executable, str(SCRIPT_DIR / 'modularization_affected_tests.py'),
                                     '--all', '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'include': [{'module': 'CoreTests'}]})

    def test_workflow_uses_full_main_module_coverage_and_supported_cache_inputs(self) -> None:
        main = (SCRIPT_DIR.parent / '.github/workflows/ci-main.yml').read_text()
        ci = (SCRIPT_DIR.parent / '.github/workflows/ci.yml').read_text()
        self.assertIn('modularization_affected_tests.py --all', ci)
        self.assertNotIn('matrix.module', main)
        self.assertIn('name: Style', ci)
        cache_save = ci.split('uses: actions/cache/save@v6', 1)[1].split('\n      - name:', 1)[0]
        self.assertNotIn('compression-level:', cache_save)
        self.assertNotIn('if-no-files-found:', cache_save)

    def test_required_style_is_final_and_mac_job_budget_is_five(self) -> None:
        ci = (SCRIPT_DIR.parent / '.github/workflows/ci.yml').read_text()
        final = ci.split('  style:', 1)[1].split('  secret-scan:', 1)[0]
        self.assertIn('name: Style', final)
        self.assertIn('needs: [build-test-bundles, build-and-test, secret-scan]', final)
        self.assertIn('if: always()', final)
        self.assertIn('ci_test_coverage.py', final)
        self.assertEqual(ci.count('runs-on: macos-26'), 2)  # one shared job + 4 matrix children
        self.assertIn('shard: [1, 2, 3, 4]', ci)
        self.assertNotIn('continue-on-error', ci)
        for line in ci.splitlines():
            if line.startswith('    name:'):
                self.assertNotIn('${{', line)

    def test_ci_typecheck_warning_classification(self) -> None:
        warning = '/checkout/Sources/RepoPrompt/App/X.swift:3:4: warning: expression took 502ms to type-check'
        self.assertEqual(ci_build.classify_warning(warning), (
            'expression', 502,
            ('Sources/RepoPrompt/App/X.swift', '3', '4', 'expression'),
        ))
        self.assertIsNone(ci_build.classify_warning(warning.replace('Sources/RepoPrompt/', 'Sources/Core/')))
        colored = warning.replace('warning:', '\x1b[1;33mwarning: \x1b[1;39m')
        self.assertEqual(ci_build.classify_warning(colored), ci_build.classify_warning(warning))

    def test_ci_typecheck_ratchet_deduplicates_reemitted_diagnostics(self) -> None:
        expression = '/checkout/Sources/RepoPrompt/App/X.swift:3:4: warning: expression took 502ms to type-check'
        function = '/checkout/Sources/RepoPrompt/App/X.swift:1:1: warning: getter took 1200ms to type-check'
        durations: dict[tuple[str, str, str, str], int] = {}
        for _ in range(25):
            ci_build.record_warning(expression, durations)
            ci_build.record_warning(function, durations)
        ci_build.record_warning(expression.replace('502ms', '505ms'), durations)
        ci_build.record_warning(expression.replace('502ms', '499ms'), durations)
        ci_build.record_warning(expression.replace('Sources/RepoPrompt/', 'Sources/Core/'), durations)
        self.assertEqual(ci_build.timing_counts(durations), {'function_body': 1, 'expression': 1})
        self.assertEqual(durations[('Sources/RepoPrompt/App/X.swift', '3', '4', 'expression')], 505)

        ci_build.record_warning(expression.replace(':3:4:', ':3:5:'), durations)
        ci_build.record_warning(function.replace(':1:1:', ':2:1:'), durations)
        self.assertEqual(ci_build.timing_counts(durations), {'function_body': 2, 'expression': 2})


if __name__ == '__main__':
    unittest.main()
