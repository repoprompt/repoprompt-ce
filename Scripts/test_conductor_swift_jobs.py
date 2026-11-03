#!/usr/bin/env python3
"""Pure command-construction contracts; never enqueue jobs or invoke Swift."""
import os
import sys
import tempfile
import subprocess
import unittest
from pathlib import Path
from unittest import mock
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import conductor
import ci_app_test_runner as runner

class SwiftJobsTests(unittest.TestCase):
    def test_swift_jobs_env_unset_uses_swiftpm_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            build_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "swift-build", "args": {"product": "RepoPrompt"}}
            )
            test_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "test", "args": {"filter": "ExampleTests"}}
            )
            provider_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "provider-test", "args": {"filter": "ExampleTests"}}
            )

        self.assertEqual(build_argv, ["swift", "build", "--product", "RepoPrompt"])
        self.assertEqual(test_argv, [sys.executable, str(Path(tmp) / "Scripts/ci_app_test_runner.py"), "--local", "--filter", "ExampleTests"])
        self.assertEqual(provider_argv, ["swift", "test", "--filter", "ExampleTests"])

    def test_request_env_is_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            with mock.patch.dict(os.environ, {"REPOPROMPT_SWIFT_JOBS": "99"}, clear=False):
                with_env = registry.prepare(
                    {
                        "operation": "swift-build",
                        "args": {"product": "RepoPrompt"},
                        "env": {"REPOPROMPT_SWIFT_JOBS": "4"},
                    }
                )
                without_env = registry.prepare(
                    {"operation": "swift-build", "args": {"product": "RepoPrompt"}, "env": {}}
                )
                empty_env = registry.prepare(
                    {
                        "operation": "swift-build",
                        "args": {"product": "RepoPrompt"},
                        "env": {"REPOPROMPT_SWIFT_JOBS": ""},
                    }
                )

        self.assertEqual(with_env[0], ["swift", "build", "--product", "RepoPrompt", "--jobs", "4"])
        self.assertEqual(without_env[0], ["swift", "build", "--product", "RepoPrompt"])
        self.assertEqual(empty_env[0], ["swift", "build", "--product", "RepoPrompt"])

    def test_swift_jobs_env_set_appends_jobs_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            env = {"REPOPROMPT_SWIFT_JOBS": "4"}
            build_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "swift-build", "args": {"product": "RepoPrompt"}, "env": env}
            )
            test_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "test", "args": {"filter": "ExampleTests"}, "env": env}
            )
            provider_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "provider-test", "args": {"filter": "ExampleTests"}, "env": env}
            )

        self.assertEqual(build_argv, ["swift", "build", "--product", "RepoPrompt", "--jobs", "4"])
        self.assertEqual(test_argv, [sys.executable, str(Path(tmp) / "Scripts/ci_app_test_runner.py"), "--local", "--filter", "ExampleTests", "--jobs", "4"])
        self.assertEqual(provider_argv, ["swift", "test", "--filter", "ExampleTests", "--jobs", "4"])
        self.assertEqual(_env["REPOPROMPT_SWIFT_JOBS"], "4")

    def test_swift_jobs_env_invalid_raises(self) -> None:
        for invalid in ["0", "-1", "abc", "01", "+1", " 1", "1.0"]:
            with self.subTest(value=invalid):
                with self.assertRaisesRegex(conductor.ConductorError, "must be a positive integer"):
                    conductor.configured_swift_jobs({"REPOPROMPT_SWIFT_JOBS": invalid})

    def test_swift_jobs_env_valid_via_os_environ(self) -> None:
        with mock.patch.dict(os.environ, {"REPOPROMPT_SWIFT_JOBS": "8"}, clear=False):
            self.assertEqual(conductor.configured_swift_jobs(), 8)

    def test_swift_jobs_env_empty_via_os_environ(self) -> None:
        with mock.patch.dict(os.environ, {"REPOPROMPT_SWIFT_JOBS": ""}, clear=False):
            self.assertIsNone(conductor.configured_swift_jobs())

    def test_swift_jobs_limit_includes_env_in_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            f1 = registry.fingerprint(
                {
                    "operation": "swift-build",
                    "args": {"product": "RepoPrompt"},
                    "env": {"REPOPROMPT_SWIFT_JOBS": "2"},
                }
            )
            f2 = registry.fingerprint(
                {
                    "operation": "swift-build",
                    "args": {"product": "RepoPrompt"},
                    "env": {"REPOPROMPT_SWIFT_JOBS": "2"},
                }
            )
            f3 = registry.fingerprint(
                {
                    "operation": "swift-build",
                    "args": {"product": "RepoPrompt"},
                    "env": {"REPOPROMPT_SWIFT_JOBS": "3"},
                }
            )
            f4 = registry.fingerprint(
                {"operation": "swift-build", "args": {"product": "RepoPrompt"}, "env": {}}
            )

        self.assertEqual(f1, f2)
        self.assertNotEqual(f1, f3)
        self.assertNotEqual(f1, f4)

    def test_non_swift_ops_unaffected_by_swift_jobs_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            env = {"REPOPROMPT_SWIFT_JOBS": "4"}
            build_argv, _, _, _, _ = registry.prepare(
                {"operation": "build", "args": {}, "env": env}
            )
            package_argv, _, _, _, _ = registry.prepare(
                {"operation": "package", "args": {"config": "release"}, "env": env}
            )
            release_argv, _, _, _, _ = registry.prepare(
                {"operation": "release", "args": {"subcommand": "package"}, "env": env}
            )
            install_argv, _, _, _, _ = registry.prepare(
                {"operation": "install-debug-cli", "args": {}, "env": env}
            )

        self.assertNotIn("--jobs", build_argv)
        self.assertNotIn("--jobs", package_argv)
        self.assertNotIn("--jobs", release_argv)
        self.assertNotIn("--jobs", install_argv)

    def test_swift_build_all_forwards_jobs_limit(self) -> None:
        with mock.patch.dict(os.environ, {"REPOPROMPT_SWIFT_JOBS": "3"}, clear=False):
            with mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run_cmd:
                code = conductor.operation_swift_build_all(Path("/tmp/repo"))

        self.assertEqual(code, 0)
        self.assertEqual(run_cmd.call_count, 2)
        for call in run_cmd.call_args_list:
            self.assertEqual(call.kwargs.get("swift_jobs_limit"), 3)
            self.assertIn("--jobs", call.args[1])
            self.assertIn("3", call.args[1])

    def test_swift_jobs_packaging_scripts_use_same_regex(self) -> None:
        for script_name in ["package_app.sh", "build_swiftpm_release_products.sh"]:
            with self.subTest(script=script_name):
                script = SCRIPT_DIR / script_name
                text = script.read_text(encoding="utf-8")
                self.assertIn("REPOPROMPT_SWIFT_JOBS", text)
                self.assertIn('[[ "$REPOPROMPT_SWIFT_JOBS" =~ ^[1-9][0-9]*$ ]]', text)
                self.assertIn('"--jobs" "$REPOPROMPT_SWIFT_JOBS"', text)

    def test_swift_jobs_shell_regex_matches_python(self) -> None:
        for value in ["0", "-1", "abc", "01", "+1", " 1", "1.0", "4", "42"]:
            with self.subTest(value=value):
                python_valid = None
                try:
                    conductor.configured_swift_jobs({"REPOPROMPT_SWIFT_JOBS": value})
                    python_valid = True
                except conductor.ConductorError:
                    python_valid = False
                result = subprocess.run(
                    ["bash", "-c", "[[ \"$1\" =~ ^[1-9][0-9]*$ ]]", "bash", value],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                shell_valid = result.returncode == 0
                self.assertEqual(
                    python_valid,
                    shell_valid,
                    f"mismatch for {value!r}: python={python_valid}, shell={shell_valid}",
                )


    def test_local_runner_forwards_jobs_without_building(self):
        with mock.patch.object(runner, "run_local_tests", return_value=0) as run:
            self.assertEqual(runner.main(["--local", "--jobs", "4"]), 0)
            self.assertEqual(run.call_args.kwargs["jobs"], 4)
        with mock.patch.object(runner, "run_module_tests", return_value=0) as run:
            self.assertEqual(runner.main(["--local", "--module", "ExampleTests", "--jobs", "4"]), 0)
            self.assertEqual(run.call_args.kwargs["jobs"], 4)

if __name__ == "__main__":
    unittest.main()
