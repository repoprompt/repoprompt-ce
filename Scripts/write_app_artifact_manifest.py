#!/usr/bin/env python3
"""Write or verify the deterministic external RepoPrompt app artifact manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, binary: bool = False) -> subprocess.CompletedProcess[Any]:
    return subprocess.run(command, capture_output=True, text=not binary, check=False)


def architectures(path: Path) -> list[str]:
    lipo = os.environ.get("LIPO", "lipo")
    result = run([lipo, "-archs", str(path)])
    if result.returncode != 0:
        fail(f"could not read architectures for {path}: {(result.stderr or '').strip()}")
    return sorted(set((result.stdout or "").split()))


def signing_details(path: Path) -> dict[str, Any]:
    codesign = os.environ.get("CODESIGN", "codesign")
    details = run([codesign, "-dv", "--verbose=4", str(path)])
    if details.returncode != 0:
        fail(f"could not read code-signing metadata for {path}")
    detail_text = "\n".join(filter(None, [details.stdout or "", details.stderr or ""]))
    values: dict[str, list[str]] = {}
    for line in detail_text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key.strip(), []).append(value.strip())

    requirement_result = run([codesign, "-d", "-r-", str(path)])
    if requirement_result.returncode != 0:
        fail(f"could not read designated requirement for {path}")
    requirement_text = "\n".join(
        filter(None, [requirement_result.stdout or "", requirement_result.stderr or ""])
    )
    designated_requirement = None
    for line in requirement_text.splitlines():
        if line.startswith("designated => "):
            designated_requirement = line.removeprefix("designated => ").strip()
            break
    if not designated_requirement:
        fail(f"signed path did not expose a designated requirement: {path}")

    entitlements_result = run([codesign, "-d", "--entitlements", ":-", str(path)], binary=True)
    entitlement_hash = None
    if entitlements_result.returncode == 0:
        candidates = [entitlements_result.stdout or b"", entitlements_result.stderr or b""]
        for candidate in candidates:
            plist_start = candidate.find(b"<?xml")
            binary_start = candidate.find(b"bplist")
            starts = [index for index in (plist_start, binary_start) if index >= 0]
            if not starts:
                continue
            payload = candidate[min(starts) :]
            try:
                parsed = plistlib.loads(payload)
            except Exception:
                continue
            canonical = plistlib.dumps(parsed, fmt=plistlib.FMT_XML, sort_keys=True)
            entitlement_hash = hashlib.sha256(canonical).hexdigest()
            break

    certificate_sha256 = None
    with tempfile.TemporaryDirectory() as temp_dir:
        prefix = Path(temp_dir) / "certificate"
        extraction = run([codesign, "-d", "--extract-certificates", str(prefix), str(path)])
        leaf = Path(f"{prefix}0")
        if extraction.returncode == 0 and leaf.is_file():
            certificate_sha256 = sha256(leaf)

    team = (values.get("TeamIdentifier") or [None])[0]
    if team in {"", "not set"}:
        team = None
    authorities = values.get("Authority", [])
    return {
        "identifier": (values.get("Identifier") or [None])[0],
        "team_identifier": team,
        "authorities": authorities,
        "designated_requirement": designated_requirement,
        "leaf_certificate_sha256": certificate_sha256,
        "entitlements_sha256": entitlement_hash,
    }


def executable_entry(app: Path, relative: str) -> dict[str, Any]:
    path = app / relative
    if not path.is_file() or path.is_symlink():
        fail(f"manifest executable must be a non-symlink regular file: {path}")
    return {
        "path": relative,
        "architectures": architectures(path),
        "sha256": sha256(path),
        "signing": signing_details(path),
    }


def collect_manifest(app: Path, expected_architectures: list[str] | None) -> dict[str, Any]:
    if not app.is_dir() or app.is_symlink():
        fail(f"app bundle must be a non-symlink directory: {app}")
    plist_path = app / "Contents" / "Info.plist"
    try:
        info = plistlib.loads(plist_path.read_bytes())
    except Exception as exc:
        fail(f"could not parse app Info.plist: {exc}")

    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        fail("Info.plist is missing CFBundleExecutable")
    entries = [
        executable_entry(app, f"Contents/MacOS/{executable_name}"),
        executable_entry(app, "Contents/MacOS/repoprompt-mcp"),
    ]
    architecture_sets = {tuple(entry["architectures"]) for entry in entries}
    if len(architecture_sets) != 1:
        fail("app and helper architecture sets differ while writing artifact manifest")
    actual_architectures = list(next(iter(architecture_sets)))
    if expected_architectures is not None and actual_architectures != expected_architectures:
        fail(
            "artifact manifest architecture mismatch: "
            f"expected {expected_architectures}, got {actual_architectures}"
        )

    bundle_signing = signing_details(app)
    if info.get("RepoPromptSigningMode") == "developer-id" and bundle_signing["entitlements_sha256"] is None:
        fail("Developer ID app did not expose parseable signed entitlements")
    return {
        "schema_version": 1,
        "bundle": {
            "identifier": info.get("CFBundleIdentifier"),
            "marketing_version": info.get("CFBundleShortVersionString"),
            "build_number": info.get("CFBundleVersion"),
            "signing_mode": info.get("RepoPromptSigningMode"),
            "architecture_policy": "universal-public"
            if actual_architectures == ["arm64", "x86_64"]
            else "host-native",
            "architectures": actual_architectures,
        },
        "bundle_signing": bundle_signing,
        "executables": entries,
    }


def canonical_bytes(manifest: dict[str, Any]) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def parse_expected(value: str | None) -> list[str] | None:
    if value is None:
        return None
    return sorted(set(part for part in value.replace(",", " ").split() if part))


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    write_parser = subparsers.add_parser("write")
    write_parser.add_argument("--app", required=True, type=Path)
    write_parser.add_argument("--output", required=True, type=Path)
    write_parser.add_argument("--expected-architectures")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--app", required=True, type=Path)
    verify_parser.add_argument("--manifest", required=True, type=Path)
    verify_parser.add_argument("--expected-architectures")
    args = parser.parse_args()

    expected = parse_expected(args.expected_architectures)
    actual = collect_manifest(args.app, expected)
    if args.command == "write":
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(f".{args.output.name}.tmp-{os.getpid()}")
        temporary.write_bytes(canonical_bytes(actual))
        os.replace(temporary, args.output)
        print(f"OK: wrote app artifact manifest: {args.output}")
        return 0

    try:
        recorded = json.loads(args.manifest.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"could not read artifact manifest {args.manifest}: {exc}")
    if canonical_bytes(recorded) != canonical_bytes(actual):
        fail(f"artifact manifest does not match app bundle: {args.manifest}")
    print(f"OK: artifact manifest matches app bundle: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
