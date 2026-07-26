#!/usr/bin/env python3
"""Prepare review-only evidence for a guarded OpenAI Codex runtime update."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import quote, urlparse

import codex_runtime_artifact as artifact


API_ROOT = "https://api.github.com/repos/openai/codex/releases"
CHECKSUM_ASSET = "codex-package_SHA256SUMS"
MAX_ASSET_SIZE = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 10_000
MAX_ARCHIVE_MEMBER_SIZE = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_ARCHIVE_SIZE = 4 * 1024 * 1024 * 1024
DEFAULT_LIPO = "/usr/bin/lipo"
DEFAULT_CODESIGN = "/usr/bin/codesign"
STABLE_VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
STABLE_TAG_PATTERN = re.compile(r"rust-v([0-9]+\.[0-9]+\.[0-9]+)")
REQUIRED_ASSET_NAMES = (
    CHECKSUM_ASSET,
    *(f"codex-package-{target}.tar.gz" for target in artifact.BUNDLE_TARGETS),
)


class CandidateError(RuntimeError):
    pass


def stable_version(value: str, *, label: str) -> str:
    if STABLE_VERSION_PATTERN.fullmatch(value) is None:
        raise CandidateError(f"{label} must be a stable numeric triplet, got {value!r}")
    return value


def version_from_tag(value: str, *, label: str) -> str:
    match = STABLE_TAG_PATTERN.fullmatch(value)
    if match is None:
        raise CandidateError(f"{label} must match rust-v<stable numeric triplet>, got {value!r}")
    return match.group(1)


def version_tuple(value: str) -> tuple[int, int, int]:
    stable_version(value, label="Codex version")
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


def ensure_newer(candidate: str, baseline: str) -> None:
    if version_tuple(candidate) <= version_tuple(baseline):
        raise CandidateError(
            f"candidate Codex {candidate} must be newer than the known-good bundled pin {baseline}"
        )


def load_json_object(path: Path, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CandidateError(f"could not read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"{label} must be a JSON object")
    return value


def github_api_json(url: str) -> dict[str, Any]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "RepoPrompt-CE-Codex-update-candidate/1",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            final_url = urlparse(response.geturl())
            if final_url.scheme != "https" or final_url.netloc != "api.github.com":
                raise CandidateError(f"GitHub release API redirected to an unexpected origin: {response.geturl()}")
            payload = response.read(10 * 1024 * 1024 + 1)
    except (OSError, urllib.error.URLError) as exc:
        raise CandidateError(f"GitHub release API request failed for {url}: {exc}") from exc
    if len(payload) > 10 * 1024 * 1024:
        raise CandidateError("GitHub release metadata exceeded the 10 MiB safety limit")
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise CandidateError(f"GitHub release API returned invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError("GitHub release API response must be a JSON object")
    return value


def selection_mode(args: argparse.Namespace) -> str:
    if args.version:
        return "explicit-version"
    if args.tag:
        return "explicit-tag"
    return "explicit-latest-stable"


def validate_evidence_mode(args: argparse.Namespace) -> None:
    if bool(args.release_json) != bool(args.asset_dir):
        raise CandidateError("--release-json and --asset-dir must be provided together for a fully offline run")
    baseline_path = Path(args.baseline_manifest).expanduser().resolve()
    has_override = (
        baseline_path != artifact.DEFAULT_MANIFEST.resolve()
        or args.lipo != DEFAULT_LIPO
        or args.codesign != DEFAULT_CODESIGN
    )
    fixture_inputs = bool(args.release_json or args.asset_dir)
    if (fixture_inputs or has_override) and not args.fixture_mode:
        raise CandidateError(
            "--fixture-mode is required for offline metadata/assets or non-default baseline/tool overrides"
        )
    if args.fixture_mode and args.latest_stable:
        raise CandidateError("--latest-stable is unavailable in fixture mode; use an explicit version or tag")


def effective_tool_path(value: str) -> str:
    resolved = shutil.which(value)
    if resolved:
        return str(Path(resolved).resolve())
    return str(Path(value).expanduser().resolve(strict=False))


def display_baseline_path(path: Path) -> str:
    try:
        return path.relative_to(artifact.ROOT.resolve()).as_posix()
    except ValueError:
        return str(path)


def build_provenance(
    args: argparse.Namespace,
    baseline_path: Path,
) -> dict[str, Any]:
    fixture_mode = bool(args.fixture_mode)
    return {
        "schemaVersion": 1,
        "evidenceMode": "test-fixture-non-promotable" if fixture_mode else "official-github-online",
        "nonPromotableTestFixture": fixture_mode,
        "selectionMode": selection_mode(args),
        "releaseMetadataSource": (
            str(Path(args.release_json).expanduser().resolve())
            if args.release_json
            else "https://api.github.com/repos/openai/codex/releases"
        ),
        "assetSources": (
            [str(Path(args.asset_dir).expanduser().resolve())]
            if args.asset_dir
            else []
        ),
        "baselineManifest": {
            "path": display_baseline_path(baseline_path),
            "sha256": artifact.sha256(baseline_path),
        },
        "verificationTools": {
            "lipo": effective_tool_path(args.lipo),
            "codesign": effective_tool_path(args.codesign),
        },
    }


def load_release(args: argparse.Namespace, expected_tag: str | None) -> dict[str, Any]:
    if args.release_json:
        return load_json_object(Path(args.release_json), label="release metadata")
    if args.latest_stable:
        url = f"{API_ROOT}/latest"
    else:
        if expected_tag is None:
            raise CandidateError("an explicit Codex tag is required")
        url = f"{API_ROOT}/tags/{quote(expected_tag, safe='')}"
    return github_api_json(url)


def required_assets(release: dict[str, Any], tag: str) -> dict[str, dict[str, Any]]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise CandidateError("release metadata assets must be a list")
    matches: dict[str, list[dict[str, Any]]] = {name: [] for name in REQUIRED_ASSET_NAMES}
    for index, raw in enumerate(assets):
        if not isinstance(raw, dict):
            raise CandidateError(f"release asset {index} is not an object")
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            raise CandidateError(f"release asset {index} has no valid name")
        if name in matches:
            matches[name].append(raw)
    selected: dict[str, dict[str, Any]] = {}
    for name in REQUIRED_ASSET_NAMES:
        values = matches[name]
        if len(values) != 1:
            raise CandidateError(f"release metadata must contain exactly one asset named {name}; found {len(values)}")
        asset_value = values[0]
        expected_url = f"{artifact.OFFICIAL_REPOSITORY_URL}/releases/download/{tag}/{name}"
        if asset_value.get("browser_download_url") != expected_url:
            raise CandidateError(f"release asset {name} must use the exact official URL {expected_url}")
        size = asset_value.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0 or size > MAX_ASSET_SIZE:
            raise CandidateError(f"release asset {name} has an invalid size: {size!r}")
        selected[name] = asset_value
    return selected


def validate_release(
    release: dict[str, Any],
    expected_tag: str | None,
) -> tuple[str, str, dict[str, dict[str, Any]]]:
    if release.get("draft") is not False:
        raise CandidateError("Codex update candidates must not use draft releases")
    if release.get("prerelease") is not False:
        raise CandidateError("Codex update candidates must not use prereleases")
    tag = release.get("tag_name")
    if not isinstance(tag, str):
        raise CandidateError("release metadata has no valid tag_name")
    version = version_from_tag(tag, label="release tag_name")
    if expected_tag is not None and tag != expected_tag:
        raise CandidateError(f"release tag mismatch: expected {expected_tag}, got {tag}")
    expected_release_url = f"{artifact.OFFICIAL_REPOSITORY_URL}/releases/tag/{tag}"
    if release.get("html_url") != expected_release_url:
        raise CandidateError(f"release html_url must be the exact official URL {expected_release_url}")
    return version, tag, required_assets(release, tag)


def path_is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def validate_output_path(path: Path) -> Path:
    resolved = path.expanduser().resolve(strict=False)
    vendor_root = (artifact.ROOT / "Vendor").resolve()
    if path_is_within(resolved, vendor_root):
        raise CandidateError("candidate output must not be written under Vendor; the live manifest is review-only")
    if resolved.exists() or resolved.is_symlink():
        raise CandidateError(f"candidate output already exists: {resolved}")
    return resolved


def download_asset(url: str, destination: Path, expected_size: int) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "RepoPrompt-CE-Codex-update-candidate/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            final_url = urlparse(response.geturl())
            if final_url.scheme != "https":
                raise CandidateError(f"asset download redirected away from HTTPS: {response.geturl()}")
            content_length = response.headers.get("Content-Length")
            if content_length is not None:
                try:
                    declared_size = int(content_length)
                except ValueError as exc:
                    raise CandidateError(f"asset response has an invalid Content-Length: {content_length!r}") from exc
                if declared_size != expected_size:
                    raise CandidateError(
                        f"asset response size disagrees with release metadata: metadata={expected_size} response={declared_size}"
                    )
            written = 0
            with destination.open("xb") as output:
                while True:
                    chunk = response.read(min(1024 * 1024, expected_size + 1 - written))
                    if not chunk:
                        break
                    output.write(chunk)
                    written += len(chunk)
                    if written > expected_size:
                        raise CandidateError(
                            f"asset download exceeded release metadata size {expected_size}: {url}"
                        )
            if written != expected_size:
                raise CandidateError(
                    f"asset download ended at {written} bytes; release metadata requires {expected_size}: {url}"
                )
    except CandidateError:
        destination.unlink(missing_ok=True)
        raise
    except (OSError, urllib.error.URLError) as exc:
        destination.unlink(missing_ok=True)
        raise CandidateError(f"asset download failed for {url}: {exc}") from exc


def acquire_assets(
    selected: dict[str, dict[str, Any]],
    destination: Path,
    asset_dir: Path | None,
) -> dict[str, Path]:
    destination.mkdir(parents=True)
    acquired: dict[str, Path] = {}
    for name in REQUIRED_ASSET_NAMES:
        output = destination / name
        if asset_dir is None:
            download_asset(
                selected[name]["browser_download_url"],
                output,
                selected[name]["size"],
            )
        else:
            source = asset_dir / name
            if not source.is_file() or source.is_symlink():
                raise CandidateError(f"offline asset directory is missing a regular file: {name}")
            source_size = source.stat().st_size
            if source_size != selected[name]["size"]:
                raise CandidateError(
                    f"offline asset size mismatch for {name}: metadata={selected[name]['size']} actual={source_size}"
                )
            shutil.copyfile(source, output)
        actual_size = output.stat().st_size
        if actual_size != selected[name]["size"]:
            raise CandidateError(
                f"release asset size mismatch for {name}: metadata={selected[name]['size']} actual={actual_size}"
            )
        acquired[name] = output
    return acquired


def verify_archive_checksums(acquired: dict[str, Path]) -> dict[str, str]:
    sums = acquired[CHECKSUM_ASSET]
    digests: dict[str, str] = {CHECKSUM_ASSET: artifact.sha256(sums)}
    for target in artifact.BUNDLE_TARGETS:
        archive = f"codex-package-{target}.tar.gz"
        published = artifact.official_digest(sums, archive)
        actual = artifact.sha256(acquired[archive])
        if actual != published:
            raise CandidateError(
                f"archive checksum mismatch for {archive}: upstream={published} actual={actual}"
            )
        digests[archive] = actual
    return digests


def archive_paths(path: Path) -> set[str]:
    discovered: set[str] = set()
    expanded_size = 0
    with tarfile.open(path, "r:gz") as tar:
        for member_count, member in enumerate(tar, start=1):
            if member_count > MAX_ARCHIVE_MEMBERS:
                raise CandidateError(f"archive exceeds the {MAX_ARCHIVE_MEMBERS} member safety limit")
            if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_SIZE:
                raise CandidateError(
                    f"archive member {member.name!r} exceeds the {MAX_ARCHIVE_MEMBER_SIZE} byte safety limit"
                )
            expanded_size += member.size
            if expanded_size > MAX_EXPANDED_ARCHIVE_SIZE:
                raise CandidateError(
                    f"archive expanded size exceeds the {MAX_EXPANDED_ARCHIVE_SIZE} byte safety limit"
                )
            normalized = member.name.rstrip("/")
            relative = str(artifact.validate_relative_path(normalized, "archive member"))
            if relative in discovered:
                raise CandidateError(f"archive contains duplicate member: {relative}")
            discovered.add(relative)
    missing = artifact.REQUIRED_LAYOUT - discovered
    if missing:
        raise CandidateError(f"candidate package omits required layout: {sorted(missing)}")
    return discovered


def structural_tree(entries: Sequence[dict[str, Any]]) -> dict[str, tuple[str, bool | None]]:
    result: dict[str, tuple[str, bool | None]] = {}
    for entry in entries:
        kind = entry["kind"]
        executable = entry.get("executable") if kind == "file" else None
        result[entry["path"]] = kind, executable
    return result


def inspect_target(
    target: str,
    archive: Path,
    destination: Path,
    baseline: dict[str, Any],
    codesign: str,
) -> tuple[Path, list[dict[str, Any]], list[str]]:
    destination.mkdir(parents=True)
    destination.chmod(artifact.EXPECTED_DIRECTORY_MODE)
    discovered = archive_paths(archive)
    artifact.safe_extract(archive, destination, discovered)
    snapshot = artifact.snapshot_tree(destination)
    actual_entries = [snapshot[path] for path in sorted(snapshot)]
    expected_entries = baseline["packages"][target]["tree"]
    actual_structure = structural_tree(actual_entries)
    expected_structure = structural_tree(expected_entries)
    if actual_structure != expected_structure:
        missing = sorted(set(expected_structure) - set(actual_structure))
        extra = sorted(set(actual_structure) - set(expected_structure))
        changed = sorted(
            path
            for path in set(actual_structure) & set(expected_structure)
            if actual_structure[path] != expected_structure[path]
        )
        raise CandidateError(
            f"{target}: package layout drift requires manual artifact-policy review"
            f"\nmissing={missing}\nextra={extra}\nchanged={changed}"
        )
    mach_o_files = sorted(
        path
        for path, entry in snapshot.items()
        if entry["kind"] == "file" and artifact.is_mach_o_file(destination / path)
    )
    baseline_mach_o = sorted(baseline["machOFiles"])
    if mach_o_files != baseline_mach_o:
        raise CandidateError(
            f"{target}: Mach-O inventory drift requires manual artifact-policy review"
            f"\nexpected={baseline_mach_o}\nactual={mach_o_files}"
        )
    entries_by_path = {entry["path"]: entry for entry in actual_entries}
    for relative in mach_o_files:
        if entries_by_path[relative].get("executable") is not True:
            raise CandidateError(f"{target}: discovered Mach-O is not executable: {relative}")
        entries_by_path[relative]["normalizedSha256"] = artifact.normalized_mach_o_sha256(
            destination / relative,
            codesign,
        )
    return destination, actual_entries, mach_o_files


def build_candidate_manifest(
    baseline: dict[str, Any],
    version: str,
    tag: str,
    digests: dict[str, str],
    trees: dict[str, list[dict[str, Any]]],
    mach_o_files: list[str],
) -> dict[str, Any]:
    download_root = f"{artifact.OFFICIAL_REPOSITORY_URL}/releases/download/{tag}"
    packages: dict[str, Any] = {}
    for target in artifact.BUNDLE_TARGETS:
        archive = f"codex-package-{target}.tar.gz"
        packages[target] = {
            "archive": archive,
            "url": f"{download_root}/{archive}",
            "sha256": digests[archive],
            "architecture": artifact.TARGET_ARCHITECTURES[target],
            "tree": trees[target],
        }
    return {
        "schemaVersion": 1,
        "version": version,
        "tag": tag,
        "releaseURL": f"{artifact.OFFICIAL_REPOSITORY_URL}/releases/tag/{tag}",
        "checksums": {
            "asset": CHECKSUM_ASSET,
            "url": f"{download_root}/{CHECKSUM_ASSET}",
            "sha256": digests[CHECKSUM_ASSET],
        },
        "packages": packages,
        "requiredLayout": copy.deepcopy(baseline["requiredLayout"]),
        "machOFiles": mach_o_files,
        "signedExecutables": copy.deepcopy(baseline["signedExecutables"]),
    }


def changed_file_paths(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    target: str,
) -> list[str]:
    baseline_entries = {entry["path"]: entry for entry in baseline["packages"][target]["tree"]}
    candidate_entries = {entry["path"]: entry for entry in candidate["packages"][target]["tree"]}
    return sorted(
        path
        for path in baseline_entries
        if baseline_entries[path].get("sha256") != candidate_entries[path].get("sha256")
        or baseline_entries[path].get("normalizedSha256") != candidate_entries[path].get("normalizedSha256")
    )


def bullet_paths(paths: Sequence[str]) -> str:
    if not paths:
        return "  - None"
    return "\n".join(f"  - `{path}`" for path in paths)


def markdown_encoded(value: str) -> str:
    return json.dumps(value, ensure_ascii=True).replace("`", "\\u0060")


def render_report(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    release: dict[str, Any],
    asset_digests: dict[str, str],
    provenance: dict[str, Any],
) -> str:
    baseline_version = baseline["version"]
    version = candidate["version"]
    tag = candidate["tag"]
    fixture_mode = provenance["nonPromotableTestFixture"]
    release_name = release.get("name") if isinstance(release.get("name"), str) else ""
    manifest_name = (
        "NON_PROMOTABLE_TEST_FIXTURE-candidate-manifest.json"
        if fixture_mode
        else "candidate-manifest.json"
    )
    lines = [
        (
            "# NON-PROMOTABLE TEST FIXTURE — Codex Runtime Candidate"
            if fixture_mode
            else "# Guarded Codex Runtime Update Candidate"
        ),
        "",
        (
            "> **NON-PROMOTABLE TEST FIXTURE:** caller-supplied metadata, assets, baseline, or tools may be present; this output is not official release evidence."
            if fixture_mode
            else "> **Review gate:** this official online evidence does not trust, apply, merge, promote Tip, or release a Codex runtime update."
        ),
        "",
        "## 1. Candidate identity and provenance",
        "",
        f"- Evidence mode: `{provenance['evidenceMode']}`.",
        f"- Candidate: Codex `{version}` (`{tag}`).",
        f"- {'Fixture-declared release URL' if fixture_mode else 'Official release'}: {candidate['releaseURL']}",
        f"- Selection mode: `{provenance['selectionMode']}`.",
        f"- Release metadata name (JSON encoded): `{markdown_encoded(release_name)}`.",
        f"- Baseline manifest path (JSON encoded): `{markdown_encoded(provenance['baselineManifest']['path'])}`; SHA-256 `{provenance['baselineManifest']['sha256']}`.",
        f"- Effective `lipo` path (JSON encoded): `{markdown_encoded(provenance['verificationTools']['lipo'])}`.",
        f"- Effective `codesign` path (JSON encoded): `{markdown_encoded(provenance['verificationTools']['codesign'])}`.",
        (
            "- Fixture metadata contained each required asset exactly once at the expected URL shape."
            if fixture_mode
            else "- Official GitHub metadata contained each required asset exactly once at its exact official URL."
        ),
    ]
    for name in sorted(REQUIRED_ASSET_NAMES):
        lines.append(f"- `{name}` SHA-256: `{asset_digests[name]}`")
    lines.extend(
        [
            "",
            f"## 2. Baseline comparison (known-good {baseline_version})",
            "",
            "- Package path/kind/executable layout matches the known-good manifest for both targets; drift would have failed the run.",
            "- Mach-O inventory and thin per-target architecture policy match the known-good manifest; drift would have failed the run.",
            "- Both primary executables match the pinned OpenAI signing identities, hardened-runtime policy, and trusted-timestamp requirement.",
        ]
    )
    for target in artifact.BUNDLE_TARGETS:
        changed = changed_file_paths(baseline, candidate, target)
        lines.extend(
            [
                f"- `{target}` changed file payloads ({len(changed)}):",
                bullet_paths(changed),
            ]
        )
    lines.extend(
        [
            "",
            "## 3. Proposed repository edits (NOT applied)",
            "",
            f"`Vendor/Codex/manifest.json` remains the single artifact authority and remains pinned to `{baseline_version}`. Review `{manifest_name}`; do not copy it into the repository until every gate below is resolved.",
            "",
            "Version-coupled surfaces requiring one reviewed rotation change include:",
            "- `Vendor/Codex/manifest.json` and `Scripts/codex_runtime_artifact.py`.",
            "- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexRuntimeAuthority.swift` and its focused tests.",
            "- `Scripts/Fixtures/codex-app-server-contract.json` and `.github/workflows/ci.yml`.",
            "- `docs/releasing.md`, `Scripts/codex_vendor_guardrails.sh`, and Codex legal inventory files.",
            "",
            "## 4. Schema-gate work",
            "",
            "- Generate app-server schemas with the candidate CLI and run `make dev-codex-schema-check`.",
            "- Reconcile every bounded request/response assumption in `Scripts/Fixtures/codex-app-server-contract.json`.",
            "- Move the contract `minimumCodexVersion` and CI `@openai/codex` pin together only after review.",
            "- A valid artifact does not prove app-server compatibility.",
            "",
            "## 5. App-server behavioral checks",
            "",
            "- Recheck `memory_mode` initialization for both fresh and resumed threads when `memories.generate_memories=false`.",
            "- Exercise `thread/start` and `thread/resume` request/response shapes and reconnect behavior.",
            "- Revalidate MCP direct-only behavior for `mcp__RepoPromptCE` and `[features.code_mode].direct_only_tool_namespaces`.",
            "- Confirm no upstream default or protocol change creates a version-specific compatibility layer in RepoPrompt.",
            "",
            "## 6. License and NOTICE review",
            "",
            "- Compare upstream `LICENSE` and `NOTICE` at the candidate tag with `ThirdPartyLicenses/codex/`.",
            "- Recheck the packaged Zsh licence, refresh the flat legal `SHA256SUMS`, and review `THIRD_PARTY_NOTICES.md`.",
            "- Artifact verification does not approve legal-text changes.",
            "",
            "## 7. External override floor policy",
            "",
            "- **UNRESOLVED MANUAL POLICY GATE:** `CodexRuntimeAuthority.minimumExternalVersion` currently equals `bundledVersion`.",
            "- This candidate makes no external override floor decision and applies no Swift edit.",
            "- A maintainer must decide explicitly whether the floor moves, then revalidate `CodexIntegrationConfiguration` direct-only contract refusal behavior and user guidance.",
            "",
            "## 8. Required validation",
            "",
            "- `python3 Scripts/test_codex_runtime_artifact.py`",
            "- `python3 Scripts/test_codex_update_candidate.py`",
            "- `make guardrails` and `make release-selftest`",
            "- Apply the reviewed candidate in a dedicated change, then run `make codex-acquire`, `make codex-status`, and `make dev-codex-schema-check`.",
            "- Run focused `CodexRuntimeAuthorityTests`, integration/app-server checks, universal release-candidate packaging, and packaged MCP smoke validation.",
            "",
            "## 9. Rollback and known-good pin",
            "",
            f"- Known-good rollback: Codex `{baseline_version}` (`{baseline['tag']}`).",
        ]
    )
    for target in artifact.BUNDLE_TARGETS:
        package = baseline["packages"][target]
        lines.append(f"- `{target}` archive SHA-256: `{package['sha256']}`")
    lines.extend(
        [
            "- Before merge, rollback means declining the candidate. After a reviewed rotation, rollback means reverting that rotation commit and rebuilding from the known-good manifest.",
            "",
            "## 10. Manual approval and soak",
            "",
            "- Explicit maintainer approval is required after artifact, schema, behavior, legal, and floor-policy review.",
            "- Do not automatically merge, promote Tip, publish stable, or treat GitHub's stable label as trust evidence.",
            "- Soak the reviewed runtime through the intended candidate/Tip process before any stable promotion; OpenAI stable releases may still contain regressions.",
            "",
        ]
    )
    return "\n".join(lines)


def sanitized_release_metadata(
    release: dict[str, Any],
    selected: dict[str, dict[str, Any]],
    digests: dict[str, str],
    provenance: dict[str, Any],
) -> dict[str, Any]:
    return {
        "evidenceMode": provenance["evidenceMode"],
        "nonPromotableTestFixture": provenance["nonPromotableTestFixture"],
        "tag_name": release["tag_name"],
        "name": release.get("name") if isinstance(release.get("name"), str) else "",
        "html_url": release["html_url"],
        "draft": release["draft"],
        "prerelease": release["prerelease"],
        "assets": [
            {
                "name": name,
                "browser_download_url": selected[name]["browser_download_url"],
                "size": selected[name]["size"],
                "sha256": digests[name],
            }
            for name in sorted(REQUIRED_ASSET_NAMES)
        ],
    }


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def write_evidence_sums(root: Path, names: Sequence[str]) -> None:
    lines = [f"{artifact.sha256(root / name)}  {name}" for name in sorted(names)]
    (root / "EVIDENCE_SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def prepare_candidate(args: argparse.Namespace) -> Path:
    validate_evidence_mode(args)

    baseline_path = Path(args.baseline_manifest).expanduser().resolve()
    baseline = artifact.load_manifest(baseline_path)
    baseline_version = baseline["version"]
    provenance = build_provenance(args, baseline_path)

    explicit_version: str | None = None
    expected_tag: str | None = None
    if args.version:
        explicit_version = stable_version(args.version, label="--version")
        expected_tag = f"rust-v{explicit_version}"
    elif args.tag:
        expected_tag = args.tag
        explicit_version = version_from_tag(expected_tag, label="--tag")
    if explicit_version is not None:
        ensure_newer(explicit_version, baseline_version)

    if args.output_dir:
        validate_output_path(Path(args.output_dir))

    release = load_release(args, expected_tag)
    version, tag, selected = validate_release(release, expected_tag)
    if not provenance["nonPromotableTestFixture"]:
        provenance["releaseMetadataSource"] = (
            f"{API_ROOT}/latest"
            if args.latest_stable
            else f"{API_ROOT}/tags/{quote(tag, safe='')}"
        )
        provenance["assetSources"] = [
            selected[name]["browser_download_url"]
            for name in sorted(REQUIRED_ASSET_NAMES)
        ]
    if explicit_version is not None and version != explicit_version:
        raise CandidateError(f"release version mismatch: expected {explicit_version}, got {version}")
    ensure_newer(version, baseline_version)

    output = validate_output_path(
        Path(args.output_dir) if args.output_dir else artifact.ROOT / ".build" / "codex-update-candidate" / tag
    )
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="repoprompt-codex-candidate-work-") as work_value:
        work = Path(work_value)
        acquired = acquire_assets(
            selected,
            work / "assets",
            Path(args.asset_dir).expanduser().resolve() if args.asset_dir else None,
        )
        digests = verify_archive_checksums(acquired)
        extracted_roots: dict[str, Path] = {}
        trees: dict[str, list[dict[str, Any]]] = {}
        inventories: dict[str, list[str]] = {}
        for target in artifact.BUNDLE_TARGETS:
            archive_name = f"codex-package-{target}.tar.gz"
            root, tree, inventory = inspect_target(
                target,
                acquired[archive_name],
                work / "extracted" / target,
                baseline,
                args.codesign,
            )
            extracted_roots[target] = root
            trees[target] = tree
            inventories[target] = inventory
        inventory_values = list(inventories.values())
        if any(value != inventory_values[0] for value in inventory_values[1:]):
            raise CandidateError("macOS targets have divergent Mach-O inventories")

        candidate = build_candidate_manifest(
            baseline,
            version,
            tag,
            digests,
            trees,
            inventory_values[0],
        )
        stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
        try:
            fixture_mode = provenance["nonPromotableTestFixture"]
            manifest_name = (
                "NON_PROMOTABLE_TEST_FIXTURE-candidate-manifest.json"
                if fixture_mode
                else "candidate-manifest.json"
            )
            manifest_path = stage / manifest_name
            write_json(manifest_path, candidate)
            verified = artifact.load_manifest(manifest_path, expected_version=version)
            for target in artifact.BUNDLE_TARGETS:
                artifact.verify_package(
                    extracted_roots[target],
                    target,
                    verified,
                    args.lipo,
                    args.codesign,
                )
            release_metadata = sanitized_release_metadata(release, selected, digests, provenance)
            write_json(stage / "release-metadata.json", release_metadata)
            write_json(stage / "candidate-provenance.json", provenance)
            shutil.copyfile(acquired[CHECKSUM_ASSET], stage / "upstream-codex-package_SHA256SUMS")
            report = render_report(baseline, verified, release, digests, provenance)
            (stage / "candidate-report.md").write_text(report, encoding="utf-8")
            evidence_names = [
                manifest_name,
                "candidate-provenance.json",
                "candidate-report.md",
                "release-metadata.json",
                "upstream-codex-package_SHA256SUMS",
            ]
            if fixture_mode:
                fixture_marker = "NON_PROMOTABLE_TEST_FIXTURE.txt"
                (stage / fixture_marker).write_text(
                    "NON-PROMOTABLE TEST FIXTURE\nThis directory is not official Codex release evidence.\n",
                    encoding="utf-8",
                )
                evidence_names.append(fixture_marker)
            write_evidence_sums(stage, evidence_names)
            os.replace(stage, output)
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare guarded, review-only evidence for an official stable Codex runtime update"
    )
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--version", help="explicit stable Codex version (for example 0.145.0)")
    selector.add_argument("--tag", help="explicit stable Codex tag (for example rust-v0.145.0)")
    selector.add_argument(
        "--latest-stable",
        action="store_true",
        help="explicitly resolve GitHub's latest stable openai/codex release",
    )
    parser.add_argument("--output-dir", help="new evidence directory; defaults under .build/codex-update-candidate")
    parser.add_argument(
        "--baseline-manifest",
        default=str(artifact.DEFAULT_MANIFEST),
        help="read-only known-good manifest baseline",
    )
    parser.add_argument(
        "--fixture-mode",
        action="store_true",
        help="mark caller-controlled/offline evidence as a non-promotable test fixture",
    )
    parser.add_argument("--release-json", help="offline release metadata fixture (requires --fixture-mode)")
    parser.add_argument("--asset-dir", help="offline directory containing required assets (requires --fixture-mode)")
    parser.add_argument("--lipo", default=DEFAULT_LIPO)
    parser.add_argument("--codesign", default=DEFAULT_CODESIGN)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        output = prepare_candidate(args)
    except (CandidateError, artifact.ContractError, OSError, UnicodeError, tarfile.TarError) as exc:
        print(f"ERROR: Codex update candidate failed: {exc}", file=sys.stderr)
        return 1
    if args.fixture_mode:
        print(f"OK: prepared NON-PROMOTABLE TEST FIXTURE evidence: {output}")
    else:
        print(f"OK: prepared official online Codex candidate evidence: {output}")
    print("REVIEW REQUIRED: no repository pin, trust decision, merge, Tip promotion, or release was performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
