#!/usr/bin/env python3
"""Acquire, assemble, verify, and stage the pinned Prompt Experiment Python runtime."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "Vendor" / "PromptExperimentPython" / "manifest.json"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


class ContractError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != 1:
        raise ContractError("Prompt Experiment runtime manifest schema must be 1")
    if set(value.get("targets", {})) != {"arm64", "x86_64"}:
        raise ContractError("Prompt Experiment runtime manifest must pin arm64 and x86_64")
    if value["gepa"].get("requiresDist") != []:
        raise ContractError("The bundled host-callback GEPA package must remain dependency-free")
    for architecture, target in value["targets"].items():
        tree_digest = target.get("treeSha256", "")
        if len(tree_digest) != 64 or any(character not in "0123456789abcdef" for character in tree_digest):
            raise ContractError(f"Prompt Experiment runtime manifest must pin the {architecture} assembled tree")
    return value


def canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def host_architecture() -> str:
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    raise ContractError(f"Unsupported packaging host architecture: {machine}")


def selected_targets(value: str) -> list[str]:
    if value == "host":
        return [host_architecture()]
    if value == "all":
        return ["arm64", "x86_64"]
    if value in {"arm64", "x86_64"}:
        return [value]
    raise ContractError(f"Unsupported architecture selector: {value}")


def verify_download(path: Path, expected_size: int, expected_sha256: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise ContractError(f"Expected a regular downloaded artifact: {path}")
    size = path.stat().st_size
    if size != expected_size:
        raise ContractError(f"{path.name}: size mismatch, expected {expected_size}, got {size}")
    actual = sha256(path)
    if actual != expected_sha256:
        raise ContractError(f"{path.name}: SHA-256 mismatch, expected {expected_sha256}, got {actual}")


def acquire_download(specification: dict, downloads: Path, asset_dir: Path | None) -> Path:
    name = specification["archive"]
    destination = downloads / name
    downloads.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        try:
            verify_download(destination, specification["size"], specification["sha256"])
            return destination
        except ContractError:
            destination.unlink()
    if asset_dir is not None:
        source = asset_dir / name
        if source.exists():
            verify_download(source, specification["size"], specification["sha256"])
            temporary = destination.with_suffix(destination.suffix + ".partial")
            shutil.copy2(source, temporary)
            os.replace(temporary, destination)
            return destination
    temporary = destination.with_suffix(destination.suffix + ".partial")
    temporary.unlink(missing_ok=True)
    print(f"Downloading {specification['url']}", flush=True)
    try:
        with urllib.request.urlopen(specification["url"]) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        verify_download(temporary, specification["size"], specification["sha256"])
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def validated_relative(name: str) -> Path:
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ContractError(f"Archive contains an unsafe path: {name}")
    return path


def extract_python(archive: Path, destination: Path) -> None:
    extraction = destination / "_python_full"
    extraction.mkdir(parents=True)
    listing = subprocess.run(
        ["tar", "--zstd", "-tf", str(archive)],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    for name in listing:
        validated_relative(name)
    available = {name.rstrip("/") for name in listing}
    missing = []
    if not any(name.startswith("python/install/") for name in available):
        missing.append("python/install/")
    if not any(name.startswith("python/licenses/") for name in available):
        missing.append("python/licenses/")
    if "python/PYTHON.json" not in available:
        missing.append("python/PYTHON.json")
    if missing:
        raise ContractError(f"Python full archive is missing required entries: {missing}")
    subprocess.run(
        [
            "tar",
            "--zstd",
            "-xf",
            str(archive),
            "-C",
            str(extraction),
            "python/install",
            "python/licenses",
            "python/PYTHON.json",
        ],
        check=True,
    )
    shutil.move(str(extraction / "python" / "install"), str(destination / "python"))
    license_root = destination / "licenses" / "python-build-standalone"
    license_root.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(extraction / "python" / "licenses"), str(license_root))
    shutil.copy2(extraction / "python" / "PYTHON.json", destination / "PYTHON.json")
    shutil.rmtree(extraction)


def copy_tar_regular(member: tarfile.TarInfo, source: tarfile.TarFile, destination: Path) -> None:
    if member.isdir():
        destination.mkdir(parents=True, exist_ok=True)
        return
    if not member.isfile():
        raise ContractError(f"GEPA source contains unsupported entry type: {member.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle = source.extractfile(member)
    if handle is None:
        raise ContractError(f"GEPA source entry is unreadable: {member.name}")
    with handle, destination.open("wb") as output:
        shutil.copyfileobj(handle, output)
    destination.chmod(0o755 if member.mode & stat.S_IXUSR else 0o644)


def install_gepa(archive: Path, destination: Path, manifest: dict) -> None:
    revision = manifest["gepa"]["revision"]
    expected_root = f"gepa-{revision}"
    package_root = destination / "python" / "lib" / "python3.11" / "site-packages"
    package_root.mkdir(parents=True, exist_ok=True)
    license_destination = destination / "licenses" / "gepa" / "LICENSE"
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        for member in members:
            relative = validated_relative(member.name)
            if not relative.parts or relative.parts[0] != expected_root:
                raise ContractError(f"GEPA source root mismatch: {member.name}")
            tail = Path(*relative.parts[1:])
            if tail == Path("LICENSE"):
                copy_tar_regular(member, source, license_destination)
            elif len(tail.parts) >= 2 and tail.parts[:2] == ("src", "gepa"):
                copy_tar_regular(member, source, package_root / Path(*tail.parts[1:]))
    if not (package_root / "gepa" / "optimize_anything.py").is_file():
        raise ContractError("GEPA source did not contain optimize_anything.py")
    if not license_destination.is_file():
        raise ContractError("GEPA source did not contain LICENSE")

    version = manifest["gepa"]["version"]
    dist_info = package_root / f"gepa-{version}.dist-info"
    dist_info.mkdir()
    metadata = (
        "Metadata-Version: 2.4\n"
        "Name: gepa\n"
        f"Version: {version}\n"
        "Summary: A framework for optimizing textual system components (AI prompts, code snippets, etc.) using LLM-based reflection and Pareto-efficient evolutionary search.\n"
        "Author: Lakshya A Agrawal\n"
        "Author-email: lakshyaaagrawal@berkeley.edu\n"
        "License: MIT\n"
        "Requires-Python: >=3.10, <3.15\n"
    )
    (dist_info / "METADATA").write_text(metadata, encoding="utf-8")
    (dist_info / "WHEEL").write_text(
        "Wheel-Version: 1.0\nGenerator: repoprompt-bundled-runtime\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        encoding="utf-8",
    )
    (dist_info / "INSTALLER").write_text("repoprompt-bundled-runtime\n", encoding="utf-8")
    (dist_info / "top_level.txt").write_text("gepa\n", encoding="utf-8")
    direct_url = {
        "url": manifest["gepa"]["repository"],
        "vcs_info": {
            "vcs": "git",
            "requested_revision": revision,
            "commit_id": revision,
        },
    }
    (dist_info / "direct_url.json").write_text(
        json.dumps(direct_url, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    write_record(package_root, dist_info)


def record_digest(path: Path) -> str:
    encoded = base64.urlsafe_b64encode(hashlib.sha256(path.read_bytes()).digest()).rstrip(b"=")
    return f"sha256={encoded.decode('ascii')}"


def write_record(site_packages: Path, dist_info: Path) -> None:
    record = dist_info / "RECORD"
    rows: list[tuple[str, str, str]] = []
    for path in sorted(site_packages.rglob("*")):
        if path.is_file() and not path.is_symlink() and path != record:
            relative = path.relative_to(site_packages).as_posix()
            rows.append((relative, record_digest(path), str(path.stat().st_size)))
    rows.append((record.relative_to(site_packages).as_posix(), "", ""))
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerows(rows)
    record.write_text(buffer.getvalue(), encoding="utf-8")


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def validate_symlinks(root: Path) -> None:
    resolved_root = root.resolve()
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        target = (path.parent / os.readlink(path)).resolve(strict=False)
        try:
            target.relative_to(resolved_root)
        except ValueError as error:
            raise ContractError(f"Runtime symlink escapes its target root: {path}") from error


def tree_entries(root: Path) -> list[dict]:
    entries: list[dict] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative == "provenance.json" or path.name == ".DS_Store" or path.is_dir():
            continue
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            entries.append({"path": relative, "kind": "symlink", "target": os.readlink(path), "mode": mode})
        elif path.is_file():
            entries.append(
                {
                    "path": relative,
                    "kind": "file",
                    "size": path.stat().st_size,
                    "sha256": sha256(path),
                    "mode": mode,
                    "mach_o": is_macho(path),
                }
            )
    return entries


def write_provenance(root: Path, architecture: str, manifest: dict, python_archive: Path, gepa_archive: Path) -> None:
    tree = tree_entries(root)
    payload = {
        "schema_version": 1,
        "runtime_version": manifest["runtimeVersion"],
        "architecture": architecture,
        "python_distribution": manifest["python"]["distribution"],
        "python_release": manifest["python"]["release"],
        "python_version": manifest["python"]["version"],
        "minimum_macos": manifest["python"]["minimumMacOS"],
        "python_asset_sha256": sha256(python_archive),
        "python_metadata_sha256": sha256(root / "PYTHON.json"),
        "gepa_version": manifest["gepa"]["version"],
        "gepa_revision": manifest["gepa"]["revision"],
        "gepa_source_sha256": sha256(gepa_archive),
        "gepa_requires_dist": manifest["gepa"]["requiresDist"],
        "tree_sha256": canonical_json_sha256(tree),
        "tree": tree,
    }
    (root / "provenance.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def verify_signed_macho(path: Path, expected_team_identifier: str) -> None:
    verification = subprocess.run(
        ["codesign", "--verify", "--strict", "--verbose=2", str(path)],
        text=True,
        capture_output=True,
    )
    if verification.returncode != 0:
        raise ContractError(f"{path}: nested Mach-O signature is invalid: {verification.stderr.strip()}")
    details = subprocess.run(
        ["codesign", "-dv", "--verbose=4", str(path)],
        text=True,
        capture_output=True,
    )
    if details.returncode != 0:
        raise ContractError(f"{path}: could not inspect nested Mach-O signing identity")
    team = next(
        (
            line.partition("=")[2]
            for line in details.stderr.splitlines()
            if line.startswith("TeamIdentifier=")
        ),
        "",
    )
    if team != expected_team_identifier:
        raise ContractError(
            f"{path}: signing team mismatch, expected {expected_team_identifier}, got {team or '<missing>'}"
        )


def verify_architectures(root: Path, architecture: str) -> None:
    for path in root.rglob("*"):
        if not is_macho(path):
            continue
        completed = subprocess.run(["lipo", "-archs", str(path)], text=True, capture_output=True)
        if completed.returncode != 0:
            raise ContractError(f"Could not inspect Mach-O architectures for {path}: {completed.stderr}")
        if architecture not in completed.stdout.split():
            raise ContractError(f"{path}: expected {architecture}, got {completed.stdout.strip()}")


def clean_runtime_smoke(root: Path, architecture: str) -> None:
    if architecture != host_architecture():
        return
    executable = root / "python" / "bin" / "python3.11"
    if not executable.is_file():
        raise ContractError(f"Bundled Python executable is missing: {executable}")
    script = (
        "import importlib.metadata,json,sys,ssl,sqlite3,lzma,zlib,ctypes;"
        "d=importlib.metadata.distribution('gepa');"
        "u=json.loads(d.read_text('direct_url.json'));"
        "assert sys.version_info[:3]==(3,11,16);"
        "assert importlib.metadata.version('gepa')=='0.1.4';"
        "assert (d.requires or [])==[];"
        "assert u['vcs_info']['commit_id']=='0632cdb5dcc052e690eab439e1b4a7e3e9cfe407';"
        "from gepa.optimize_anything import optimize_anything"
    )
    with tempfile.TemporaryDirectory(prefix="RPCE Runtime Smoke With Spaces ") as temporary:
        temp = Path(temporary)
        home = temp / "Empty Home"
        scratch = temp / "Scratch"
        home.mkdir()
        scratch.mkdir()
        environment = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(scratch),
            "PYTHONHOME": "/definitely/invalid/python-home",
            "PYTHONPATH": "/definitely/invalid/python-path",
            "PYTHONDONTWRITEBYTECODE": "0",
        }
        completed = subprocess.run(
            [str(executable), "-I", "-B", "-u", "-c", script],
            cwd=str(temp),
            env=environment,
            text=True,
            capture_output=True,
        )
        if completed.returncode != 0:
            raise ContractError(f"Relocated clean-environment runtime smoke failed: {completed.stderr or completed.stdout}")


def verify_target(
    root: Path,
    architecture: str,
    manifest: dict,
    allow_signed_macho: bool = False,
    signed_team_identifier: str | None = None,
) -> None:
    if signed_team_identifier and not allow_signed_macho:
        raise ContractError("--signed-team-identifier requires --allow-signed-macho")
    provenance_path = root / "provenance.json"
    if not provenance_path.is_file() or provenance_path.is_symlink():
        raise ContractError(f"Missing target provenance: {provenance_path}")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    expected = manifest["targets"][architecture]
    exact = {
        "schema_version": 1,
        "runtime_version": manifest["runtimeVersion"],
        "architecture": architecture,
        "python_distribution": manifest["python"]["distribution"],
        "python_release": manifest["python"]["release"],
        "python_version": manifest["python"]["version"],
        "minimum_macos": manifest["python"]["minimumMacOS"],
        "python_asset_sha256": expected["sha256"],
        "tree_sha256": expected["treeSha256"],
        "gepa_version": manifest["gepa"]["version"],
        "gepa_revision": manifest["gepa"]["revision"],
        "gepa_source_sha256": manifest["gepa"]["source"]["sha256"],
        "gepa_requires_dist": manifest["gepa"]["requiresDist"],
    }
    for key, value in exact.items():
        if provenance.get(key) != value:
            raise ContractError(f"{root}: provenance mismatch for {key}")
    provenance_tree = provenance.get("tree", [])
    if canonical_json_sha256(provenance_tree) != expected["treeSha256"]:
        raise ContractError(f"{root}: assembled runtime tree is not pinned by the developer manifest")
    expected_entries = {entry["path"]: entry for entry in provenance_tree}
    actual_entries = {entry["path"]: entry for entry in tree_entries(root)}
    if set(actual_entries) != set(expected_entries):
        raise ContractError(f"{root}: runtime tree paths changed")
    for relative, expected_entry in expected_entries.items():
        actual = actual_entries[relative]
        if expected_entry["kind"] != actual["kind"]:
            raise ContractError(f"{root / relative}: entry kind changed")
        if expected_entry.get("mach_o", False) != actual.get("mach_o", False):
            raise ContractError(f"{root / relative}: Mach-O classification changed")
        if expected_entry["mode"] != actual["mode"]:
            raise ContractError(f"{root / relative}: file mode changed")
        if expected_entry["kind"] == "symlink":
            if expected_entry["target"] != actual["target"]:
                raise ContractError(f"{root / relative}: symlink target changed")
        elif allow_signed_macho and expected_entry.get("mach_o"):
            if signed_team_identifier:
                verify_signed_macho(root / relative, signed_team_identifier)
        elif expected_entry["sha256"] != actual["sha256"] or expected_entry["size"] != actual["size"]:
            raise ContractError(f"{root / relative}: file digest or size changed")
    validate_symlinks(root)
    verify_architectures(root, architecture)
    clean_runtime_smoke(root, architecture)


def assemble_target(
    target: str,
    destination: Path,
    manifest: dict,
    python_archive: Path,
    gepa_archive: Path,
) -> None:
    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{target}-", dir=parent))
    try:
        extract_python(python_archive, temporary)
        install_gepa(gepa_archive, temporary, manifest)
        for bytecode in temporary.rglob("*.py[co]"):
            bytecode.unlink()
        for cache in sorted(temporary.rglob("__pycache__"), reverse=True):
            if cache.is_dir():
                cache.rmdir()
        validate_symlinks(temporary)
        write_provenance(temporary, target, manifest, python_archive, gepa_archive)
        verify_target(temporary, target, manifest)
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def acquire(args: argparse.Namespace, manifest: dict) -> None:
    cache = Path(args.cache_root).resolve()
    downloads = cache / "downloads"
    asset_dir = Path(args.asset_dir).resolve() if args.asset_dir else None
    gepa_spec = dict(manifest["gepa"]["source"])
    gepa_spec["archive"] = "gepa-source.tar.gz"
    gepa_archive = acquire_download(gepa_spec, downloads, asset_dir)
    for target in selected_targets(args.arch):
        destination = cache / manifest["runtimeVersion"] / target
        if destination.exists():
            try:
                verify_target(destination, target, manifest)
                print(f"OK: verified cached Prompt Experiment runtime: {destination}")
                continue
            except ContractError as error:
                print(f"Repairing invalid cached Prompt Experiment runtime: {error}", file=sys.stderr)
                shutil.rmtree(destination)
        python_archive = acquire_download(manifest["targets"][target], downloads, asset_dir)
        assemble_target(target, destination, manifest, python_archive, gepa_archive)
        print(f"OK: assembled Prompt Experiment runtime: {destination}")


def verify_worker_resource(source: Path, worker: Path) -> None:
    """Reject incomplete or stale packages before signing/launching the debug app."""
    for path in (source, worker):
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"Expected a regular GEPA worker resource: {path}")
    source_bytes = source.read_bytes()
    if worker.read_bytes() != source_bytes:
        raise ContractError("Packaged GEPA worker differs from the checked-in worker")
    try:
        compile(source_bytes, str(worker), "exec")
    except (SyntaxError, ValueError) as error:
        raise ContractError("Packaged GEPA worker is not valid Python") from error


def verify_worker(args: argparse.Namespace, manifest: dict) -> None:
    worker = Path(args.worker).absolute()
    verify_worker_resource(Path(args.source_worker).absolute(), worker)
    bundle = Path(args.runtime_bundle).resolve()
    for target in selected_targets(args.arch):
        if target != host_architecture():
            continue
        executable = bundle / target / "python" / "bin" / "python3.11"
        with tempfile.TemporaryDirectory(prefix="RPCE Worker Preflight With Spaces ") as temporary:
            root = Path(temporary)
            home, scratch = root / "home", root / "tmp"
            home.mkdir()
            scratch.mkdir()
            completed = subprocess.run(
                [str(executable), "-I", "-B", "-u", str(worker), "--preflight"],
                cwd=root,
                env={"HOME": str(home), "PATH": "/usr/bin:/bin", "TMPDIR": str(scratch)},
                stdin=subprocess.DEVNULL,
                text=True,
                capture_output=True,
                timeout=30,
            )
        try:
            ready = json.loads(completed.stdout)
        except (TypeError, ValueError) as error:
            raise ContractError("Packaged GEPA worker did not return a readiness response") from error
        expected = {
            "protocol_version": 2,
            "type": "ready",
            "python_version": [int(part) for part in manifest["python"]["version"].split(".")],
            "gepa_version": manifest["gepa"]["version"],
            "upstream_revision": manifest["gepa"]["revision"],
        }
        if completed.returncode != 0 or ready != expected:
            raise ContractError("Packaged GEPA worker does not match its pinned runtime/protocol")
    print(f"OK: verified packaged GEPA worker (no model calls): {worker}")


def stage_bundle(args: argparse.Namespace, manifest: dict) -> None:
    cache = Path(args.cache_root).resolve()
    bundle = Path(args.bundle).resolve()
    bundle.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".PromptExperimentPython-", dir=bundle.parent))
    try:
        for target in selected_targets(args.arch):
            source = cache / manifest["runtimeVersion"] / target
            verify_target(source, target, manifest)
            shutil.copytree(source, temporary / target, symlinks=True)
        shutil.copy2(Path(args.manifest), temporary / "manifest.json")
        if bundle.exists():
            shutil.rmtree(bundle)
        os.replace(temporary, bundle)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    print(f"OK: staged Prompt Experiment runtime bundle: {bundle}")


def verify_bundle(args: argparse.Namespace, manifest: dict) -> None:
    bundle = Path(args.bundle).resolve()
    for target in selected_targets(args.arch):
        verify_target(
            bundle / target,
            target,
            manifest,
            allow_signed_macho=args.allow_signed_macho,
            signed_team_identifier=args.signed_team_identifier,
        )
    print(f"OK: verified Prompt Experiment runtime bundle: {bundle}")


def macho_paths(args: argparse.Namespace, manifest: dict) -> None:
    bundle = Path(args.bundle).resolve()
    paths: list[Path] = []
    for target in selected_targets(args.arch):
        provenance = json.loads((bundle / target / "provenance.json").read_text(encoding="utf-8"))
        paths.extend(
            (bundle / target / entry["path"]).resolve()
            for entry in provenance["tree"]
            if entry.get("mach_o")
        )
    for path in sorted(paths, key=lambda candidate: (-len(candidate.parts), candidate.as_posix())):
        print(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("manifest-version")

    acquire_parser = subparsers.add_parser("acquire")
    acquire_parser.add_argument("--arch", default="host")
    acquire_parser.add_argument("--cache-root", required=True)
    acquire_parser.add_argument("--asset-dir", default=os.environ.get("REPOPROMPT_PROMPT_EXPERIMENT_ASSET_DIR"))

    stage_parser = subparsers.add_parser("stage-bundle")
    stage_parser.add_argument("--arch", default="host")
    stage_parser.add_argument("--cache-root", required=True)
    stage_parser.add_argument("--bundle", required=True)

    verify_parser = subparsers.add_parser("verify-bundle")
    verify_parser.add_argument("--arch", default="host")
    verify_parser.add_argument("--bundle", required=True)
    verify_parser.add_argument("--allow-signed-macho", action="store_true")
    verify_parser.add_argument("--signed-team-identifier")

    worker_parser = subparsers.add_parser("verify-worker")
    worker_parser.add_argument("--arch", default="host")
    worker_parser.add_argument("--source-worker", required=True)
    worker_parser.add_argument("--worker", required=True)
    worker_parser.add_argument("--runtime-bundle", required=True)

    paths_parser = subparsers.add_parser("mach-o-paths")
    paths_parser.add_argument("--arch", default="host")
    paths_parser.add_argument("--bundle", required=True)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    manifest_path = Path(args.manifest).resolve()
    manifest = load_manifest(manifest_path)
    args.manifest = str(manifest_path)
    if args.command == "manifest-version":
        print(manifest["runtimeVersion"])
    elif args.command == "acquire":
        acquire(args, manifest)
    elif args.command == "stage-bundle":
        stage_bundle(args, manifest)
    elif args.command == "verify-bundle":
        verify_bundle(args, manifest)
    elif args.command == "verify-worker":
        verify_worker(args, manifest)
    elif args.command == "mach-o-paths":
        macho_paths(args, manifest)
    else:
        parser.error(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        main()
    except (ContractError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
