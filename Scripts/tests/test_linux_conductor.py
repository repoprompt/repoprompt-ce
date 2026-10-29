import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import conductor


class LinuxConductorTests(unittest.TestCase):
    def test_build_child_preserves_proxy_and_ca_configuration(self):
        network = {
            "HTTP_PROXY": "http://proxy.invalid:8080",
            "HTTPS_PROXY": "http://proxy.invalid:8080",
            "ALL_PROXY": "socks5://proxy.invalid:1080",
            "NO_PROXY": "localhost,127.0.0.1",
            "http_proxy": "http://proxy.invalid:8080",
            "https_proxy": "http://proxy.invalid:8080",
            "all_proxy": "socks5://proxy.invalid:1080",
            "no_proxy": "localhost,127.0.0.1",
            "SSL_CERT_FILE": "/tmp/company-ca.pem",
            "SSL_CERT_DIR": "/tmp/company-certs",
            "CURL_CA_BUNDLE": "/tmp/company-ca.pem",
            "GIT_SSL_CAINFO": "/tmp/company-ca.pem",
            "GIT_SSL_CAPATH": "/tmp/company-certs",
            "REQUESTS_CA_BUNDLE": "/tmp/company-ca.pem",
        }
        with patch.dict(os.environ, {**network, "UNRELATED_SECRET": "excluded"}, clear=True):
            snapshot = conductor.OperationRegistry.client_env_snapshot()
        _, _, _, env, _ = conductor.OperationRegistry(Path("/tmp/repo")).prepare({
            "operation": "swift-build", "args": {"product": "repoprompt-mcp"}, "env": snapshot,
        })
        child_env = json.loads(subprocess.check_output(
            [sys.executable, "-c", "import json, os; print(json.dumps(dict(os.environ)))"],
            env=env, text=True, timeout=10,
        ))
        self.assertEqual({key: child_env.get(key) for key in network}, network)
        self.assertNotIn("UNRELATED_SECRET", child_env)

    def test_release_build_preserves_coordination_and_compiler_options(self):
        registry = conductor.OperationRegistry(Path("/tmp/rpce-build-test"))
        argv, lanes, cwd, _, _ = registry.prepare({
            "operation": "swift-build",
            "args": {"product": "repoprompt-mcp", "config": "release", "jobs": 2, "staticSwiftStdlib": True},
        })
        self.assertEqual(argv, ["swift", "build", "--product", "repoprompt-mcp", "--configuration", "release", "--jobs", "2", "--static-swift-stdlib"])
        self.assertEqual(lanes, ["build"])
        self.assertEqual(cwd, Path("/tmp/rpce-build-test"))
        self.assertEqual(conductor.BuildCacheManager.configuration_for("swift-build", {"config": "release"}), "release")

    def test_default_build_command_is_unchanged(self):
        registry = conductor.OperationRegistry(Path("/tmp/rpce-build-test"))
        argv, lanes, _, _, _ = registry.prepare({"operation": "swift-build", "args": {"product": "repoprompt-mcp"}})
        self.assertEqual(argv, ["swift", "build", "--product", "repoprompt-mcp"])
        self.assertEqual(lanes, ["build"])

    def test_linux_state_uses_absolute_xdg_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sys, "platform", "linux"), patch.dict(os.environ, {"XDG_STATE_HOME": directory, "REPOPROMPT_DEV_DAEMON_STATE_DIR": ""}):
                paths = conductor.compute_paths(Path(directory) / "repo")
            self.assertEqual(paths.state_dir.parent, Path(directory) / "repoprompt-ce/conductor")

    def test_relative_xdg_state_is_ignored(self):
        with patch.object(sys, "platform", "linux"), patch.dict(os.environ, {"XDG_STATE_HOME": "relative", "REPOPROMPT_DEV_DAEMON_STATE_DIR": ""}):
            paths = conductor.compute_paths(Path("/tmp/repo"))
        self.assertEqual(paths.state_dir.parent, Path.home() / ".local/state/repoprompt-ce/conductor")

    def test_linux_tests_use_swiftpm_with_filter(self):
        with patch.object(sys, "platform", "linux"):
            argv, lanes, _, _, _ = conductor.OperationRegistry(Path("/tmp/repo")).prepare({
                "operation": "test", "args": {"filter": "DomainMutationPathFenceTests"},
            })
        self.assertEqual(argv, ["swift", "test", "--jobs", "4", "--filter", "DomainMutationPathFenceTests"])
        self.assertEqual(lanes, ["build"])

    def test_linux_all_builds_only_the_real_supported_product(self):
        with patch.object(sys, "platform", "linux"), patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run:
            self.assertEqual(conductor.operation_swift_build_all(Path("/tmp/repo"), ["--configuration", "release"]), 0)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[1], ["swift", "build", "--product", "repoprompt-mcp", "--configuration", "release"])


if __name__ == "__main__":
    unittest.main()
