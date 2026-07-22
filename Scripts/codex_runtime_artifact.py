#!/usr/bin/env python3
"""Acquire and verify the repository-pinned OpenAI Codex standalone package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "Vendor" / "Codex" / "manifest.json"
DEFAULT_CACHE_ROOT = ROOT / ".build" / "codex-runtime"
# Compatibility authority shared with the schema-gate branch that must land first.
# Pin rotations intentionally update these values and Vendor/Codex/manifest.json together.
SUPPORTED_VERSION = "0.144.6"
SUPPORTED_TAG = f"rust-v{SUPPORTED_VERSION}"
OFFICIAL_REPOSITORY_URL = "https://github.com/openai/codex"
OFFICIAL_RELEASE_URL = f"{OFFICIAL_REPOSITORY_URL}/releases/tag/{SUPPORTED_TAG}"
OFFICIAL_DOWNLOAD_URL = f"{OFFICIAL_REPOSITORY_URL}/releases/download/{SUPPORTED_TAG}"
REQUIRED_LAYOUT = {
    "codex-package.json",
    "bin/codex",
    "bin/codex-code-mode-host",
    "codex-resources",
    "codex-path",
}
BUNDLE_TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
)
TARGET_ARCHITECTURES = {
    "aarch64-apple-darwin": "arm64",
    "x86_64-apple-darwin": "x86_64",
}
EXPECTED_DIRECTORY_MODE = 0o755


class ContractError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"could not read pinned manifest {path}: {exc}") from exc
    if manifest.get("schemaVersion") != 1:
        raise ContractError("unsupported Codex manifest schema")
    if manifest.get("version") != SUPPORTED_VERSION or manifest.get("tag") != SUPPORTED_TAG:
        raise ContractError(f"pinned manifest must describe Codex {SUPPORTED_VERSION} / {SUPPORTED_TAG}")
    if manifest.get("releaseURL") != OFFICIAL_RELEASE_URL:
        raise ContractError(f"pinned manifest releaseURL must be {OFFICIAL_RELEASE_URL}")
    packages = manifest.get("packages")
    if not isinstance(packages, dict) or set(packages) != set(BUNDLE_TARGETS):
        raise ContractError("pinned manifest must contain exactly both macOS package targets")
    if set(manifest.get("requiredLayout", [])) != REQUIRED_LAYOUT:
        raise ContractError("pinned manifest requiredLayout is incomplete or unexpected")
    checksums = manifest.get("checksums")
    if not isinstance(checksums, dict) or checksums.get("asset") != "codex-package_SHA256SUMS":
        raise ContractError("pinned manifest has an invalid official checksum asset")
    validate_digest(checksums.get("sha256"), "official checksum asset")
    expected_checksums_url = f"{OFFICIAL_DOWNLOAD_URL}/{checksums['asset']}"
    if checksums.get("url") != expected_checksums_url:
        raise ContractError(f"official checksum asset URL must be {expected_checksums_url}")
    for target, package in packages.items():
        if not isinstance(package, dict):
            raise ContractError(f"{target}: package contract is not an object")
        expected_archive = f"codex-package-{target}.tar.gz"
        if package.get("archive") != expected_archive:
            raise ContractError(f"{target}: expected official archive {expected_archive}")
        if package.get("architecture") != TARGET_ARCHITECTURES[target]:
            raise ContractError(f"{target}: architecture policy mismatch")
        validate_digest(package.get("sha256"), f"{target} archive")
        expected_package_url = f"{OFFICIAL_DOWNLOAD_URL}/{expected_archive}"
        if package.get("url") != expected_package_url:
            raise ContractError(f"{target}: official archive URL must be {expected_package_url}")
        entries = package.get("tree")
        if not isinstance(entries, list):
            raise ContractError(f"{target}: missing tree contract")
        paths = [entry.get("path") for entry in entries]
        if len(paths) != len(set(paths)):
            raise ContractError(f"{target}: duplicate paths in tree contract")
        if not REQUIRED_LAYOUT.issubset(set(paths)):
            raise ContractError(f"{target}: tree contract omits required package layout")
        for entry in entries:
            validate_relative_path(entry.get("path"), f"{target} manifest path")
            if entry.get("kind") not in {"directory", "file"}:
                raise ContractError(f"{target}: unsupported manifest entry kind")
            if entry.get("kind") == "file":
                validate_digest(entry.get("sha256"), f"{target} file {entry.get('path')}")
                if not isinstance(entry.get("executable"), bool):
                    raise ContractError(f"{target}: missing executable policy for {entry.get('path')}")
    mach_o_files = manifest.get("machOFiles")
    if not isinstance(mach_o_files, list) or set(mach_o_files) != {
        "bin/codex",
        "bin/codex-code-mode-host",
        "codex-path/rg",
        "codex-resources/zsh/bin/zsh",
    }:
        raise ContractError("pinned manifest is missing Mach-O architecture policy")
    for target, package in packages.items():
        entries_by_path = {entry["path"]: entry for entry in package["tree"]}
        for relative in mach_o_files:
            entry = entries_by_path.get(relative)
            if not entry or entry.get("kind") != "file" or entry.get("executable") is not True:
                raise ContractError(f"{target}: Mach-O policy path is not a pinned executable file: {relative}")
    signed = manifest.get("signedExecutables")
    if not isinstance(signed, list) or {item.get("path") for item in signed if isinstance(item, dict)} != {
        "bin/codex",
        "bin/codex-code-mode-host",
    }:
        raise ContractError("pinned manifest must contain both primary executable signature policies")
    for policy in signed:
        if not isinstance(policy, dict):
            raise ContractError("invalid executable signature policy")
        for key in ("path", "identifier", "teamIdentifier", "authority"):
            if not isinstance(policy.get(key), str) or not policy[key]:
                raise ContractError(f"invalid executable signature policy field: {key}")
        if policy.get("requiresHardenedRuntime") is not True:
            raise ContractError(f"{policy['path']}: hardened runtime must be required")
        if policy.get("requiresTimestamp") is not True:
            raise ContractError(f"{policy['path']}: a trusted signing timestamp must be required")
    return manifest


def validate_digest(raw: object, context: str) -> str:
    if not isinstance(raw, str) or len(raw) != 64 or any(char not in "0123456789abcdef" for char in raw):
        raise ContractError(f"invalid SHA-256 for {context}")
    return raw


def validate_relative_path(raw: object, context: str) -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        raise ContractError(f"{context}: empty path")
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts or "." in path.parts or str(path) != raw:
        raise ContractError(f"{context}: unsafe path {raw!r}")
    return path


def selected_targets(value: str) -> list[str]:
    if value == "all":
        return list(BUNDLE_TARGETS)
    return [normalize_target(value)]


def normalize_target(value: str) -> str:
    if value == "host":
        machine = platform.machine()
        if machine in {"arm64", "aarch64"}:
            return "aarch64-apple-darwin"
        if machine == "x86_64":
            return "x86_64-apple-darwin"
        raise ContractError(f"unsupported host architecture: {machine}")
    aliases = {
        "arm64": "aarch64-apple-darwin",
        "aarch64": "aarch64-apple-darwin",
        "aarch64-apple-darwin": "aarch64-apple-darwin",
        "x86_64": "x86_64-apple-darwin",
        "x86_64-apple-darwin": "x86_64-apple-darwin",
    }
    try:
        return aliases[value]
    except KeyError as exc:
        raise ContractError(f"unsupported Codex architecture/target: {value}") from exc


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "RepoPrompt-CE-Codex-artifact/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
            if urlparse(response.geturl()).scheme != "https":
                raise ContractError(f"download redirected away from HTTPS: {response.geturl()}")
            shutil.copyfileobj(response, output)
    except Exception as exc:
        raise ContractError(f"download failed for {url}: {exc}") from exc


def official_digest(sums_path: Path, asset: str) -> str:
    matches: list[str] = []
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        fields = line.strip().split()
        if len(fields) == 2 and fields[1].lstrip("*") == asset:
            matches.append(fields[0].lower())
    if len(matches) != 1:
        raise ContractError(f"official checksum file must contain exactly one entry for {asset}")
    digest = matches[0]
    if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
        raise ContractError(f"official checksum for {asset} is not a SHA-256 digest")
    return digest


def run_tool(argv: list[str], description: str) -> str:
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise ContractError(f"could not run {description}: {exc}") from exc
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise ContractError(f"{description} failed ({' '.join(argv)}):\n{output.strip()}")
    return output


def parse_codesign_metadata(details: str) -> dict[str, list[str]]:
    fields: dict[str, list[str]] = {}
    for raw_line in details.splitlines():
        line = raw_line.strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"Identifier", "TeamIdentifier", "Authority", "Timestamp"}:
            fields.setdefault(key, []).append(value)
    return fields


def verify_directory_mode(path: Path, context: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != EXPECTED_DIRECTORY_MODE:
        raise ContractError(f"{context} directory mode must be 0755, got {mode:04o}: {path}")


def snapshot_tree(root: Path) -> dict[str, dict[str, Any]]:
    if not root.is_dir() or root.is_symlink():
        raise ContractError(f"package root is not a real directory: {root}")
    verify_directory_mode(root, "package root")
    snapshot: dict[str, dict[str, Any]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ContractError(f"package contains an unsupported symbolic link: {relative}")
        if path.is_dir():
            verify_directory_mode(path, f"package directory {relative}")
            snapshot[relative] = {"path": relative, "kind": "directory"}
        elif path.is_file():
            snapshot[relative] = {
                "path": relative,
                "kind": "file",
                "sha256": sha256(path),
                "executable": bool(path.stat().st_mode & 0o111),
            }
        else:
            raise ContractError(f"package contains an unsupported file type: {relative}")
    return snapshot


def verify_package(
    root: Path,
    target: str,
    manifest: dict[str, Any],
    lipo: str,
    codesign: str,
) -> None:
    package = manifest["packages"][target]
    expected = {entry["path"]: entry for entry in package["tree"]}
    actual = snapshot_tree(root)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(path for path in set(actual) & set(expected) if actual[path] != expected[path])
        raise ContractError(
            f"{target}: package tree does not match pinned manifest"
            f"\nmissing={missing}\nextra={extra}\nchanged={changed}"
        )
    metadata_path = root / "codex-package.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"{target}: invalid codex-package.json: {exc}") from exc
    expected_metadata = {
        "layoutVersion": 1,
        "version": manifest["version"],
        "target": target,
        "variant": "codex",
        "entrypoint": "bin/codex",
        "resourcesDir": "codex-resources",
        "pathDir": "codex-path",
    }
    if metadata != expected_metadata:
        raise ContractError(f"{target}: codex-package.json metadata mismatch")
    expected_arch = package["architecture"]
    for relative in manifest["machOFiles"]:
        output = run_tool([lipo, "-archs", str(root / relative)], f"architecture check for {relative}")
        architectures = output.strip().split()
        if architectures != [expected_arch]:
            raise ContractError(
                f"{target}: {relative} architectures {architectures!r} do not equal [{expected_arch!r}]"
            )
    for policy in manifest["signedExecutables"]:
        binary = root / policy["path"]
        run_tool([codesign, "--verify", "--strict", "--verbose=2", str(binary)], f"signature check for {policy['path']}")
        details = run_tool([codesign, "-dv", "--verbose=4", str(binary)], f"signature metadata for {policy['path']}")
        fields = parse_codesign_metadata(details)
        exact_single_fields = {
            "Identifier": policy["identifier"],
            "TeamIdentifier": policy["teamIdentifier"],
        }
        for key, expected in exact_single_fields.items():
            actual = fields.get(key, [])
            if actual != [expected]:
                raise ContractError(
                    f"{target}: {policy['path']} signature metadata {key} must equal {expected!r}, got {actual!r}"
                )
        authorities = fields.get("Authority", [])
        if not authorities or authorities[0] != policy["authority"]:
            raise ContractError(
                f"{target}: {policy['path']} leaf signing authority must equal {policy['authority']!r},"
                f" got {authorities!r}"
            )
        if not re.search(r"^CodeDirectory .*flags=.*\([^)]*\bruntime\b[^)]*\)", details, re.MULTILINE):
            raise ContractError(f"{target}: {policy['path']} is missing the hardened-runtime signing flag")
        timestamps = fields.get("Timestamp", [])
        if len(timestamps) != 1 or not timestamps[0].strip() or timestamps[0].strip().casefold() == "none":
            raise ContractError(f"{target}: {policy['path']} is missing a trusted signing timestamp")


def safe_extract(archive: Path, destination: Path, expected_paths: set[str]) -> None:
    seen: set[str] = set()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            normalized = member.name.rstrip("/")
            path = validate_relative_path(normalized, "archive member")
            relative = str(path)
            if relative in seen:
                raise ContractError(f"archive contains duplicate member: {relative}")
            seen.add(relative)
            if relative not in expected_paths:
                raise ContractError(f"archive contains unpinned member: {relative}")
            if not (member.isdir() or member.isfile()):
                raise ContractError(f"archive contains unsupported member type: {relative}")
        if seen != expected_paths:
            raise ContractError(f"archive layout mismatch: missing={sorted(expected_paths - seen)} extra={sorted(seen - expected_paths)}")
        for member in members:
            relative = member.name.rstrip("/")
            output = destination / relative
            if member.isdir():
                # File members may have created parents before an explicit directory member.
                output.mkdir(parents=True, exist_ok=True)
                output.chmod(0o755)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                if source is None:
                    raise ContractError(f"could not read archive member: {relative}")
                with source, output.open("xb") as handle:
                    shutil.copyfileobj(source, handle)
                output.chmod(0o755 if member.mode & 0o111 else 0o644)


def verify_sources(sums: Path, archive: Path, package: dict[str, Any], checksums: dict[str, Any]) -> None:
    if sha256(sums) != checksums["sha256"]:
        raise ContractError("official checksum asset does not match the repository-pinned digest")
    published = official_digest(sums, package["archive"])
    if published != package["sha256"]:
        raise ContractError("official checksum and repository-pinned archive digest disagree")
    actual = sha256(archive)
    if actual != published:
        raise ContractError(f"archive checksum mismatch: expected {published}, got {actual}")


def acquire_target(
    target: str,
    manifest: dict[str, Any],
    cache_root: Path,
    source_dir: Path,
    lipo: str,
    codesign: str,
) -> Path:
    final = cache_root / manifest["version"] / target
    if final.exists():
        verify_package(final, target, manifest, lipo, codesign)
        print(f"OK: verified cached Codex {manifest['version']} package: {final}")
        return final
    package = manifest["packages"][target]
    sums = source_dir / manifest["checksums"]["asset"]
    archive = source_dir / package["archive"]
    verify_sources(sums, archive, package, manifest["checksums"])
    final.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=f".{target}.", dir=final.parent))
    try:
        temp.chmod(EXPECTED_DIRECTORY_MODE)
        expected_paths = {entry["path"] for entry in package["tree"]}
        safe_extract(archive, temp, expected_paths)
        verify_package(temp, target, manifest, lipo, codesign)
        os.replace(temp, final)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    print(f"OK: acquired and verified Codex {manifest['version']} {target}: {final}")
    return final


def verify_bundle(
    root: Path,
    targets: list[str],
    manifest: dict[str, Any],
    lipo: str,
    codesign: str,
) -> None:
    if not root.is_dir() or root.is_symlink():
        raise ContractError(f"Codex bundle root is not a real directory: {root}")
    verify_directory_mode(root, "Codex bundle root")
    actual_targets = {path.name for path in root.iterdir()}
    expected_targets = set(targets)
    if actual_targets != expected_targets:
        raise ContractError(
            "Codex bundle target layout mismatch"
            f"\nmissing={sorted(expected_targets - actual_targets)}"
            f"\nextra={sorted(actual_targets - expected_targets)}"
        )
    for target in targets:
        package = root / target
        if not package.is_dir() or package.is_symlink():
            raise ContractError(f"Codex bundle target is not a real directory: {package}")
        verify_package(package, target, manifest, lipo, codesign)
    print(f"OK: verified bundled Codex {manifest['version']} targets: {', '.join(targets)}")


def stage_bundle(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    targets = selected_targets(args.arch)
    cache_root = Path(args.cache_root)
    destination = Path(args.bundle)
    if destination.exists() or destination.is_symlink():
        raise ContractError(f"Codex bundle destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=f".{destination.name}.", dir=destination.parent))
    try:
        temp.chmod(EXPECTED_DIRECTORY_MODE)
        for target in targets:
            source = cache_root / manifest["version"] / target
            verify_package(source, target, manifest, args.lipo, args.codesign)
            staged_target = temp / target
            shutil.copytree(source, staged_target)
            staged_target.chmod(EXPECTED_DIRECTORY_MODE)
        verify_bundle(temp, targets, manifest, args.lipo, args.codesign)
        os.replace(temp, destination)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    print(f"OK: staged Codex {manifest['version']} bundle: {destination}")


def acquire(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    targets = selected_targets(args.arch)
    cache_root = Path(args.cache_root)
    missing: list[str] = []
    for target in targets:
        cached = cache_root / manifest["version"] / target
        if cached.exists():
            verify_package(cached, target, manifest, args.lipo, args.codesign)
            print(f"OK: verified cached Codex {manifest['version']} package: {cached}")
        else:
            missing.append(target)
    if not missing:
        return
    with tempfile.TemporaryDirectory(prefix="repoprompt-codex-download-") as temp_value:
        temp = Path(temp_value)
        source = Path(args.archive_dir).resolve() if args.archive_dir else temp
        sums = source / manifest["checksums"]["asset"]
        if not args.archive_dir:
            print(f"Downloading official checksum asset for {manifest['tag']}...")
            download(manifest["checksums"]["url"], sums)
            if sha256(sums) != manifest["checksums"]["sha256"]:
                raise ContractError("official checksum asset does not match the repository-pinned digest")
            for target in missing:
                package = manifest["packages"][target]
                print(f"Downloading official {package['archive']}...")
                download(package["url"], source / package["archive"])
        for target in missing:
            acquire_target(target, manifest, cache_root, source, args.lipo, args.codesign)


def status(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    failed = False
    for target in BUNDLE_TARGETS:
        path = Path(args.cache_root) / manifest["version"] / target
        if not path.exists():
            print(f"MISSING: {target}: {path}")
            failed = True
            continue
        try:
            verify_package(path, target, manifest, args.lipo, args.codesign)
        except ContractError as exc:
            print(f"INVALID: {target}: {exc}")
            failed = True
        else:
            print(f"OK: {target}: {path}")
    if failed:
        raise ContractError("one or more pinned Codex packages are unavailable or invalid")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--lipo", default=os.environ.get("LIPO", "lipo"))
    parser.add_argument("--codesign", default=os.environ.get("CODESIGN", "codesign"))
    subparsers = parser.add_subparsers(dest="command", required=True)
    acquire_parser = subparsers.add_parser("acquire", help="download, verify, and atomically cache official packages")
    acquire_parser.add_argument("--arch", default="all", help="all, host, arm64, x86_64, or an exact target")
    acquire_parser.add_argument("--cache-root", default=str(DEFAULT_CACHE_ROOT))
    acquire_parser.add_argument("--archive-dir", help="offline directory containing the official checksum asset and archives")
    verify_parser = subparsers.add_parser("verify", help="verify an extracted package without network access")
    verify_parser.add_argument("--arch", required=True)
    verify_parser.add_argument("--package", required=True)
    stage_bundle_parser = subparsers.add_parser(
        "stage-bundle",
        help="copy verified cached packages into the stable target-specific bundle layout",
    )
    stage_bundle_parser.add_argument("--arch", default="all")
    stage_bundle_parser.add_argument("--cache-root", default=str(DEFAULT_CACHE_ROOT))
    stage_bundle_parser.add_argument("--bundle", required=True)
    verify_bundle_parser = subparsers.add_parser(
        "verify-bundle",
        help="verify the exact stable target-specific bundle layout without network access",
    )
    verify_bundle_parser.add_argument("--arch", default="all")
    verify_bundle_parser.add_argument("--bundle", required=True)
    status_parser = subparsers.add_parser("status", help="verify both cached packages without network access")
    status_parser.add_argument("--cache-root", default=str(DEFAULT_CACHE_ROOT))
    subparsers.add_parser("validate-manifest", help="validate the repository pin without network or cached packages")
    subparsers.add_parser("manifest-version", help="print the validated pinned version for packaging paths")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        manifest = load_manifest(Path(args.manifest))
        if args.command == "acquire":
            acquire(args, manifest)
        elif args.command == "verify":
            verify_package(Path(args.package), normalize_target(args.arch), manifest, args.lipo, args.codesign)
            print(f"OK: verified pinned Codex package: {args.package}")
        elif args.command == "stage-bundle":
            stage_bundle(args, manifest)
        elif args.command == "verify-bundle":
            verify_bundle(Path(args.bundle), selected_targets(args.arch), manifest, args.lipo, args.codesign)
        elif args.command == "status":
            status(args, manifest)
        elif args.command == "manifest-version":
            print(manifest["version"])
        else:
            print(f"OK: pinned Codex manifest is valid: {args.manifest}")
    except (ContractError, OSError, tarfile.TarError) as exc:
        print(f"ERROR: Codex artifact contract failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
