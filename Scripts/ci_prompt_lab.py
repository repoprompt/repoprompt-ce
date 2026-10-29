#!/usr/bin/env python3
"""Prepare isolated GEPA/DSPy environments and require every lab test to run."""

from __future__ import annotations

import argparse
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import venv


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Vendor" / "PromptExperimentPython" / "manifest.json"
DSPY_VERSION = "3.4.1"
SUITES = {
    "worker": ROOT / "Scripts" / "test_gepa_prompt_experiment_worker.py",
    "program": ROOT / "Scripts" / "test_prompt_program_runner.py",
}


def prepare(directory: Path) -> None:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("Prepare the pinned worker layout with Python 3.11")
    sys.path.insert(0, str(ROOT / "Scripts"))
    from prompt_experiment_runtime_artifact import acquire_download, install_gepa, load_manifest

    directory.mkdir(parents=True, exist_ok=False)
    manifest = load_manifest(MANIFEST)
    specification = dict(manifest["gepa"]["source"], archive="gepa-source.tar.gz")
    archive = acquire_download(specification, directory / "downloads", None)
    worker = directory / "gepa"
    venv.EnvBuilder(with_pip=False).create(worker / "python")
    install_gepa(archive, worker, manifest)
    project = directory / "dspy"
    venv.EnvBuilder(with_pip=True).create(project)
    subprocess.run([
        str(project / "bin" / "python"), "-m", "pip", "install", "--disable-pip-version-check",
        "--retries", "2", "--timeout", "30", f"dspy=={DSPY_VERSION}",
    ], check=True, timeout=600)


def verify_environment(kind: str) -> None:
    if kind == "worker":
        expected = json.loads(MANIFEST.read_text())["gepa"]
        package = importlib.metadata.distribution("gepa")
        direct = json.loads(package.read_text("direct_url.json") or "{}")
        if (package.version != expected["version"]
                or direct.get("vcs_info", {}).get("commit_id") != expected["revision"]
                or (package.requires or []) != expected["requiresDist"]):
            raise RuntimeError("Worker tests require the exact dependency-free GEPA manifest revision")
    else:
        if importlib.metadata.version("dspy") != DSPY_VERSION:
            raise RuntimeError(f"Program tests require dspy=={DSPY_VERSION}")
        worker = os.environ.get("REPOPROMPT_TEST_GEPA_PYTHON")
        if not worker or not os.path.isfile(worker) or not os.access(worker, os.X_OK):
            raise RuntimeError("The real GEPA-to-DSPy integration interpreter is required")


def run_suite(path: Path, *, stream=None) -> bool:
    specification = importlib.util.spec_from_file_location("prompt_lab_ci_suite", path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"Cannot load test suite: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    if result.skipped or result.testsRun == 0:
        print("Prompt Lab CI requires nonempty suites with no skipped tests.", file=sys.stderr)
        return False
    return result.wasSuccessful()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("prepare", help="Create two fresh environments with manifest-pinned GEPA and DSPy")
    setup.add_argument("--directory", type=Path, required=True)
    tests = commands.add_parser("test", help="Run both complete suites, failing on any skip")
    tests.add_argument("--gepa-python", type=Path, required=True)
    tests.add_argument("--dspy-python", type=Path, required=True)
    suite = commands.add_parser("_suite", help=argparse.SUPPRESS)
    suite.add_argument("kind", choices=SUITES)
    arguments = parser.parse_args()
    if arguments.command == "prepare":
        prepare(arguments.directory)
    elif arguments.command == "_suite":
        verify_environment(arguments.kind)
        return 0 if run_suite(SUITES[arguments.kind]) else 1
    else:
        # Keep the venv executable path: resolving its symlink would select the host interpreter.
        worker = arguments.gepa_python.expanduser().absolute()
        project = arguments.dspy_python.expanduser().absolute()
        environment = dict(os.environ, REPOPROMPT_TEST_GEPA_PYTHON=str(worker))
        for executable, kind in [(worker, "worker"), (project, "program")]:
            subprocess.run(
                [str(executable), "-I", "-B", str(Path(__file__).resolve()), "_suite", kind],
                env=environment, check=True, timeout=300,
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
