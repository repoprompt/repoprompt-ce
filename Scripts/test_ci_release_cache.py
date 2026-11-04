#!/usr/bin/env python3
"""Release cache compatibility and workflow trust boundaries."""
import tempfile
from pathlib import Path
import unittest

import ci_release_cache as cache


class ReleaseCacheTests(unittest.TestCase):
    def test_root_cache_excludes_cleaned_products_and_attempt_evidence(self):
        ci = (Path(__file__).resolve().parent.parent / '.github/workflows/ci.yml').read_text()
        for marker in ('Restore SwiftPM dependencies and provider support cache',
                       'Save SwiftPM dependencies and provider support cache (main only)'):
            step = ci.split('      - name: ' + marker, 1)[1].split('\n      - name:', 1)[0]
            self.assertNotIn('            .build\n', step)
            self.assertNotIn('.build/modularization', step)
            self.assertNotIn('.build/ci-test-results', step)
            self.assertNotIn('github.sha', step)
            self.assertNotIn('restore-keys:', step)
            self.assertNotIn('.build/swiftbuild', step)

    def test_cache_key_failures_are_not_masked_and_signed_releases_stay_clean(self):
        workflows = Path(__file__).resolve().parent.parent / '.github/workflows'
        for name in ('ci.yml', 'release-candidate.yml'):
            workflow = (workflows / name).read_text()
            self.assertNotIn('echo "key=$(', workflow)
            self.assertIn('[[ "$key" =~ ^swiftpm-release-v2-[0-9a-f]{64}$ ]]', workflow)
        for name in ('main-tip.yml', 'release.yml'):
            workflow = (workflows / name).read_text()
            self.assertNotIn('actions/cache/', workflow)
            self.assertNotIn('REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS: "0"', workflow)
        validate = (workflows / 'release.yml').read_text().split('\n  validate-ref:\n', 1)[1].split('\n  stage:\n', 1)[0]
        self.assertIn('runs-on: ubuntu-latest', validate)

    def test_manual_main_only_seed_follows_fresh_package_and_smoke(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/release-candidate.yml').read_text()
        save = workflow.split('      - name: Seed universal release build cache', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn("github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'", save)
        self.assertNotIn('always()', save)
        self.assertNotIn('restore-keys:', workflow)
        self.assertIn('path: .build/public-release-swiftpm', save)
        self.assertLess(workflow.index('run: ./conductor release artifact'),
                        workflow.index('name: Smoke exact release-mode packaged MCP helper'))
        self.assertLess(workflow.index('name: Smoke exact release-mode packaged MCP helper'),
                        workflow.index('name: Seed universal release build cache'))
        self.assertLess(workflow.index('name: Transfer the same candidate'),
                        workflow.index('name: Seed universal release build cache'))
        self.assertNotIn('secrets: inherit', workflow)
        self.assertNotIn('contents: write', workflow)

    def test_only_compatible_intermediates_share_a_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('Package.swift', 'Package.resolved', *cache.POLICY_FILES,
                         'Vendor/Local/Package.swift', 'Packages/Provider/Package.swift', 'Packages/Provider/Package.resolved',
                         'Scripts/patches/dependency.patch'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            toolchain = {'architecture': 'arm64', 'xcode': '26', 'swift': '6.2',
                         'sdk_path': '/sdk', 'sdk_version': '26', 'image_version': '1'}
            original = cache.key(root, root, False, toolchain)
            self.assertEqual(original, cache.key(root, root, False, dict(reversed(list(toolchain.items())))))
            self.assertNotEqual(original, cache.key(root, root, True, toolchain))
            for field in toolchain:
                with self.subTest(field=field):
                    self.assertNotEqual(original, cache.key(root, root, False, {**toolchain, field: 'changed'}))
            for path in [p for p in root.rglob('*') if p.is_file()]:
                previous = path.read_text()
                path.write_text(previous + 'changed')
                with self.subTest(path=path.relative_to(root)):
                    self.assertNotEqual(original, cache.key(root, root, False, toolchain))
                path.write_text(previous)
            # Current first-party sources must still be built; the compatibility
            # key deliberately does not create an immutable cache for every commit.
            for name in ('Sources/App.swift', '.build/admission.json',
                         'Packages/Provider/.build/checkouts/Other/Package.swift'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('not cache compatibility policy')
            self.assertEqual(original, cache.key(root, root, False, toolchain))
            moved = root.with_name(root.name + '-moved')
            root.rename(moved)
            try:
                self.assertNotEqual(original, cache.key(moved, moved, False, toolchain))
            finally:
                moved.rename(root)
            (root / 'Package.resolved').unlink()
            with self.assertRaises(FileNotFoundError):
                cache.key(root, root, False, toolchain)


if __name__ == '__main__':
    unittest.main()
