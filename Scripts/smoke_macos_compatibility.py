#!/usr/bin/env python3
"""Run a transferred release artifact on an explicitly selected older macOS.

No compilation, signing, or installation is performed. The existing isolated
packaged MCP roundtrip owns app launch, readiness checks, and teardown.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile

from ci_process_session import defer_cancellation_during_cleanup, terminate_session

SCRIPTS = Path(__file__).resolve().parent


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_host(version: str, architecture: str, expected_major: int, expected_arch: str) -> None:
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version) or int(version.split(".")[0]) != expected_major:
        raise ValueError(f"requires macOS {expected_major}.x, observed {version!r}; newer OS results do not count")
    if architecture != expected_arch:
        raise ValueError(f"requires {expected_arch}, observed {architecture!r}")


def release_inputs(directory: Path) -> tuple[Path, Path]:
    archives = sorted([*directory.glob("*.zip"), *directory.glob("*.pkg")])
    manifests = sorted(directory.glob("*-artifact-manifest.json"))
    if len(archives) != 1 or len(manifests) != 1:
        raise ValueError("expected exactly one release ZIP or transition PKG and one artifact manifest")
    checksums = directory / "SHA256SUMS"
    for path in [*archives, *manifests, checksums]:
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"expected a regular, non-symlink artifact: {path.name}")
    entries: dict[str, str] = {}
    for line in checksums.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
        if not match or match[2] in entries:
            raise ValueError("malformed or duplicate SHA256SUMS entry")
        entries[match[2]] = match[1].lower()
    for path in [*archives, *manifests]:
        if entries.get(path.name) != digest(path):
            raise ValueError(f"SHA256SUMS mismatch or missing entry: {path.name}")
    return archives[0], manifests[0]


def smoke_process(command: list[str], environment: dict[str, str]) -> None:
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    try:
        result = process.wait(timeout=420)
        if result:
            raise subprocess.CalledProcessError(result, command)
    finally:
        with defer_cancellation_during_cleanup():
            terminate_session(process)


def check_artifact(directory: Path, expected_major: int, expected_arch: str,
                   report: dict, diagnostics: Path) -> None:
    version = subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"], text=True).strip()
    architecture = platform.machine()
    report["host"] = {"macos": version, "architecture": architecture}
    verify_host(version, architecture, expected_major, expected_arch)
    archive, manifest = release_inputs(directory)
    report["artifact"] = {"name": archive.name, "sha256": digest(archive), "manifest_sha256": digest(manifest)}

    # No GitHub tokens or release/signing credentials reach the launched app.
    environment = {name: os.environ[name] for name in ("HOME", "USER", "LOGNAME", "TMPDIR") if name in os.environ}
    environment["PATH"] = f"{Path(sys.executable).parent}:/usr/bin:/bin:/usr/sbin:/sbin"
    environment.update(REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="240",
                       REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="60",
                       REPOPROMPT_PACKAGED_SMOKE_DIAGNOSTICS_DIR=str(diagnostics.resolve()))
    with tempfile.TemporaryDirectory(prefix="rpce-macos-compatibility-") as temporary:
        extracted = Path(temporary) / "extracted"
        if archive.suffix == ".pkg":
            environment["REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG"] = "1"
            subprocess.run([str(SCRIPTS / "build_identity_transition_pkg.sh"), "validate", str(archive),
                            "--expanded-payload-dir", str(extracted)], env=environment, check=True, timeout=180)
        else:
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)],
                           env=environment, check=True, timeout=180)
        app = extracted / "RepoPrompt CE.app"
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        # Keep the coverage gap visible when the product's supported floor moves.
        minimum = str(info.get("LSMinimumSystemVersion", ""))
        if not re.fullmatch(r"14\.\d+(?:\.\d+)?", minimum):
            raise ValueError(f"review compatibility policy for minimum macOS {minimum!r}")
        report["minimum_macos"] = minimum
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                       env=environment, check=True, timeout=120)
        subprocess.run([sys.executable, str(SCRIPTS / "validate_macos_runtime_symbols.py"), str(app)],
                       env=environment, check=True, timeout=150)
        smoke_process([str(SCRIPTS / "smoke_packaged_mcp_roundtrip.sh"), str(app),
                       f"macOS {expected_major} {expected_arch} compatibility", str(manifest)], environment)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--expected-major", type=int, required=True)
    parser.add_argument("--expected-arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = {"schema": 1, "result": "failed", "expected_macos_major": args.expected_major,
              "expected_architecture": args.expected_arch}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    # Overwrite stale success before attempting any validation.
    args.report.write_text(json.dumps(report, indent=2) + "\n")

    def cancel(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    try:
        check_artifact(args.artifacts.resolve(), args.expected_major, args.expected_arch, report, args.report.parent)
        report["result"] = "passed"
        print(f"OK: release artifact launched and MCP responded on macOS {args.expected_major} {args.expected_arch}")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        report["error"] = str(error)
        print(f"ERROR: macOS compatibility smoke failed: {error}", file=sys.stderr)
        return 1
    finally:
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
