#!/usr/bin/env python3
"""Bounded, resumable publication for one immutable Tip release context.

The public release protocol is deliberately separate from artifact construction:

1. authenticate the exact protected-main and live rollout state;
2. create or resume one matching draft;
3. upload only missing assets and authenticate every remote byte;
4. publish the audited draft; and
5. repeat the complete audit anonymously, including every retained P/T
   enclosure required by delayed upgraders.

Every external/network operation runs through
``supervise_release_phase.run_supervised``. This orchestrator never starts an
external child by any other path and never retries, sleeps, overwrites an
asset, or deletes a release/tag.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import hashlib
import json
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import types
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Iterator

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

# Never write in-tree bytecode: an untracked __pycache__ would fail the
# strict trusted-root clean-checkout verification.
sys.dont_write_bytecode = True

import stable_rollout as rollout  # noqa: E402
import supervise_release_phase as supervisor  # noqa: E402
import tip_release_context as context_tool  # noqa: E402

LOWER_SHA256 = re.compile(r"[0-9a-f]{64}")
LOWER_COMMIT = re.compile(r"[0-9a-f]{40}")
SAFE_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_RELEASE_LOOKUP_PAGES = 100
DEFAULT_COMMAND_TIMEOUT_SECONDS = 300.0
DEFAULT_ASSET_TIMEOUT_SECONDS = 900.0
MAX_PUBLICATION_TIMEOUT_SECONDS = 3600.0
SOURCE_REPOSITORY = "repoprompt/repoprompt-ce"
ALLOWED_DOWNLOAD_HOSTS = {
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "uploads.github.com",
}
PROHIBITED_AMBIENT_AUTHORITY_ALIASES = (
    "TIP_UPDATE_REPOSITORY",
    "TIP_PUBLISH_INSTALLATION_TYPE",
    "RELEASE_COMMIT",
    "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE",
    "BUILD_NUMBER",
    "GH_TOKEN",
)


class PublicationError(Exception):
    pass


class GitHubRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Allow reviewed GitHub redirects without forwarding credentials cross-host."""

    def redirect_request(self, request, fp, code, message, headers, new_url):
        validate_download_url(new_url, expected_basename=None, api_only=False)
        redirected = super().redirect_request(
            request, fp, code, message, headers, new_url
        )
        if redirected is None:
            return None
        old_host = (urllib.parse.urlparse(request.full_url).hostname or "").casefold()
        new_host = (urllib.parse.urlparse(new_url).hostname or "").casefold()
        if old_host != new_host:
            redirected.remove_header("Authorization")
        return redirected


GITHUB_URL_OPENER = urllib.request.build_opener(GitHubRedirectHandler())


@dataclasses.dataclass(frozen=True)
class AssetExpectation:
    name: str
    path: Path
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class RemoteAsset:
    name: str
    api_url: str
    browser_url: str


@dataclasses.dataclass(frozen=True)
class ReleasePlan:
    release_id: int
    state: str
    remote_assets: tuple[RemoteAsset, ...]
    missing_assets: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class EnclosureExpectation:
    role: str
    tag: str
    name: str
    url: str
    size: int
    sha256: str


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def phase_start(name: str, **fields: object) -> float:
    details = " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
    print(f"PHASE START [{utc_timestamp()}]: {name}{' ' if details else ''}{details}", flush=True)
    return dt.datetime.now(dt.timezone.utc).timestamp()


def phase_complete(name: str, started: float, **fields: object) -> None:
    elapsed = max(0.0, dt.datetime.now(dt.timezone.utc).timestamp() - started)
    details = " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
    print(
        f"PHASE COMPLETE [{utc_timestamp()}]: {name} elapsed-seconds={elapsed:.3f}"
        f"{' ' if details else ''}{details}",
        flush=True,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PublicationError(f"missing {label}: {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise PublicationError(f"{label} must be a regular non-symlink file: {path}")


def require_real_directory(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PublicationError(f"missing {label}: {path}: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise PublicationError(f"{label} must be a real non-symlink directory: {path}")


def write_private_json(path: Path, value: object) -> None:
    if path.exists() or path.is_symlink():
        raise PublicationError(f"refusing to replace publication work file: {path}")
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    require_regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublicationError(f"unreadable {label}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise PublicationError(f"{label} must be a JSON object")
    return value


def safe_basename(value: str, label: str) -> str:
    if not value or Path(value).name != value or value in {".", ".."}:
        raise PublicationError(f"{label} must be one safe basename, got {value!r}")
    if any(character in value for character in ("\x00", "\r", "\n", "\t")):
        raise PublicationError(f"{label} contains a prohibited control character")
    return value


def expected_release_title(context: dict[str, Any]) -> str:
    release = context["release"]
    role = context["rollout"]["role"]
    return f"{release['displayName']} Tip {role} {release['shortSha']}"


def expected_release_notes(context: dict[str, Any]) -> str:
    release = context["release"]
    role = context["rollout"]["role"]
    return (
        f"Tip identity rollout role `{role}` from main commit `{release['commit']}` "
        f"with build number `{release['buildNumber']}`."
    )


def validate_release_provenance(
    workflow_definition: str,
    tooling: str,
    selected_source: str,
    protected_main: str,
) -> None:
    values = {
        "workflow-definition": workflow_definition,
        "tooling": tooling,
        "selected-source": selected_source,
        "protected-main": protected_main,
    }
    for label, value in values.items():
        if LOWER_COMMIT.fullmatch(value) is None:
            raise PublicationError(f"Tip release {label} must be a full lowercase commit SHA")
    if len(set(values.values())) != 1:
        detail = " ".join(f"{label}={value}" for label, value in values.items())
        raise PublicationError(
            f"Tip release provenance skew: {detail}; refusing before credentials or builds"
        )


def run_validate_provenance(args: argparse.Namespace) -> int:
    # Reject local workflow/tooling/source skew before making even the bounded,
    # anonymous protected-main request.
    validate_release_provenance(
        args.workflow_definition_commit,
        args.tooling_commit,
        args.selected_source_commit,
        args.selected_source_commit,
    )
    if args.repository != SOURCE_REPOSITORY:
        raise PublicationError(
            f"protected-main repository must remain {SOURCE_REPOSITORY}, got {args.repository!r}"
        )
    tooling_root = Path(args.trusted_tooling_root)
    require_real_directory(tooling_root, "trusted tooling root")
    work_root = Path(tempfile.mkdtemp(prefix="repoprompt-tip-provenance-"))
    try:
        runner = PublicationRunner(
            work_dir=work_root,
            dist_dir=tooling_root,
            total_asset_bytes=0,
            token_env="TIP_GH_TOKEN",
            command_timeout=args.command_timeout_seconds,
            asset_timeout=args.command_timeout_seconds,
        )
        protected_main = fetch_live_main(
            runner,
            args.selected_source_commit,
            "fresh protected source main verification",
            repository=args.repository,
        )
        validate_release_provenance(
            args.workflow_definition_commit,
            args.tooling_commit,
            args.selected_source_commit,
            protected_main,
        )
        print(
            "OK: Tip release workflow definition, tooling, selected source, and freshly "
            f"fetched protected main are exactly {protected_main}."
        )
        return 0
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def parse_checksums(path: Path) -> dict[str, str]:
    require_regular_file(path, "Tip SHA256SUMS")
    entries: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PublicationError(f"cannot read Tip SHA256SUMS: {error}") from error
    for position, line in enumerate(lines, start=1):
        fields = line.split()
        if len(fields) != 2 or LOWER_SHA256.fullmatch(fields[0]) is None:
            raise PublicationError(f"SHA256SUMS line {position} is malformed")
        name = safe_basename(fields[1].removeprefix("*"), f"SHA256SUMS line {position} name")
        if name in entries:
            raise PublicationError(f"SHA256SUMS repeats asset {name}")
        entries[name] = fields[0]
    return entries


def build_local_asset_expectations(
    context: dict[str, Any],
    dist_dir: Path,
    setup_context: Path,
    setup_digest: Path,
    expected_checksums_sha256: str | None,
) -> tuple[dict[str, AssetExpectation], str]:
    if (
        expected_checksums_sha256 is not None
        and LOWER_SHA256.fullmatch(expected_checksums_sha256) is None
    ):
        raise PublicationError("trusted sign-job SHA256SUMS digest must be lowercase SHA-256")
    require_real_directory(dist_dir, "Tip publication directory")
    names = context["publication"]["assets"]
    if not isinstance(names, list) or not names or len(names) != len(set(names)):
        raise PublicationError("verified Tip publication asset inventory is malformed")
    expected_names = {safe_basename(str(name), "Tip publication asset") for name in names}
    try:
        actual_names = set(os.listdir(dist_dir))
    except OSError as error:
        raise PublicationError(f"cannot enumerate Tip publication directory: {error}") from error
    if actual_names != expected_names:
        raise PublicationError(
            "Tip publication directory inventory mismatch: "
            f"missing={sorted(expected_names - actual_names) or 'none'} "
            f"extra={sorted(actual_names - expected_names) or 'none'}"
        )
    asset_paths = {name: dist_dir / name for name in expected_names}
    # Prove every input is a regular non-symlink before opening any one of them.
    # This makes FIFOs and other nonregular entries fail without a blocking read.
    for name in sorted(expected_names):
        require_regular_file(asset_paths[name], f"Tip publication asset {name}")
    for path, label in ((setup_context, "setup context"), (setup_digest, "setup digest")):
        require_regular_file(path, label)
    dist_context = asset_paths["tip-release-context.json"]
    dist_digest = asset_paths["tip-release-context.json.sha256"]
    if dist_context.read_bytes() != setup_context.read_bytes():
        raise PublicationError("published Tip context differs byte-for-byte from setup")
    if dist_digest.read_bytes() != setup_digest.read_bytes():
        raise PublicationError("published Tip context digest differs byte-for-byte from setup")
    checksums = asset_paths["SHA256SUMS"]
    actual_checksums_sha256 = sha256_file(checksums)
    if (
        expected_checksums_sha256 is not None
        and actual_checksums_sha256 != expected_checksums_sha256
    ):
        raise PublicationError("SHA256SUMS differs from the trusted sign-job digest")
    checksum_entries = parse_checksums(checksums)
    expected_checksum_names = expected_names - {"SHA256SUMS"}
    if set(checksum_entries) != expected_checksum_names:
        raise PublicationError(
            "SHA256SUMS entry set mismatch: "
            f"missing={sorted(expected_checksum_names - set(checksum_entries)) or 'none'} "
            f"extra={sorted(set(checksum_entries) - expected_checksum_names) or 'none'}"
        )
    expectations: dict[str, AssetExpectation] = {}
    for name in sorted(expected_names):
        path = asset_paths[name]
        digest = actual_checksums_sha256 if name == "SHA256SUMS" else checksum_entries[name]
        actual_digest = sha256_file(path)
        if actual_digest != digest:
            raise PublicationError(
                f"local Tip asset digest mismatch for {name}: actual={actual_digest} expected={digest}"
            )
        expectations[name] = AssetExpectation(name, path, path.lstat().st_size, digest)
    return expectations, actual_checksums_sha256


def preflight_local_inputs(args: argparse.Namespace) -> Path:
    """lstat every caller-owned setup path before context resolution reads bytes."""

    dist_dir = Path(args.dist_dir)
    require_real_directory(dist_dir, "Tip publication directory")
    for name in PROHIBITED_AMBIENT_AUTHORITY_ALIASES:
        if name in os.environ:
            raise PublicationError(f"Ambient legacy Tip authority alias is prohibited: {name}")
    for value, label in (
        (args.context, "setup context"),
        (args.digest, "setup digest"),
        (args.stable_appcast, "setup stable appcast"),
    ):
        require_regular_file(Path(value), label)
    for value, label in (
        (args.approved_source_root, "approved source root"),
        (args.trusted_tooling_root, "trusted tooling root"),
    ):
        require_real_directory(Path(value), label)
    return dist_dir


def write_github_output(path: Path, name: str, value: str) -> None:
    require_regular_file(path, "GitHub output file")
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(f"{name}={value}\n")


def run_validate_local_assets(args: argparse.Namespace) -> int:
    dist_dir = preflight_local_inputs(args)
    context = verify_context(args)
    expectations, checksums_sha256 = build_local_asset_expectations(
        context,
        dist_dir,
        Path(args.context),
        Path(args.digest),
        args.expected_sha256sums_sha256,
    )
    if args.github_output:
        write_github_output(
            Path(args.github_output), "sha256sums-sha256", checksums_sha256
        )
    print(
        f"OK: Tip publication asset inventory contains exactly {len(expectations)} files; "
        "context and SHA256SUMS are setup/sign-job bound."
    )
    return 0


def validate_release_metadata(
    context: dict[str, Any],
    release: dict[str, Any],
    expectations: dict[str, AssetExpectation],
) -> ReleasePlan:
    release_id = release.get("id")
    if not isinstance(release_id, int) or release_id <= 0:
        raise PublicationError("GitHub release response has a malformed release id")
    expected_fields = {
        "tag_name": context["release"]["tag"],
        "target_commitish": context["publication"]["target"],
        "name": expected_release_title(context),
        "body": expected_release_notes(context),
        "prerelease": False,
    }
    for key, expected in expected_fields.items():
        actual = release.get(key)
        if actual != expected:
            raise PublicationError(
                f"GitHub release metadata mismatch for {key}: actual={actual!r} expected={expected!r}"
            )
    draft = release.get("draft")
    if not isinstance(draft, bool):
        raise PublicationError("GitHub release draft flag is malformed")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise PublicationError("GitHub release assets must be a list")
    remote: list[RemoteAsset] = []
    seen: set[str] = set()
    for position, asset in enumerate(assets, start=1):
        if not isinstance(asset, dict):
            raise PublicationError(f"GitHub release asset {position} must be an object")
        name = safe_basename(str(asset.get("name", "")), f"GitHub release asset {position}")
        if name in seen:
            raise PublicationError(f"GitHub release repeats asset {name}")
        seen.add(name)
        expectation = expectations.get(name)
        if expectation is None:
            raise PublicationError(f"GitHub release contains unexpected asset {name}")
        if asset.get("state") != "uploaded":
            raise PublicationError(
                f"GitHub release asset {name} is not fully uploaded; the no-delete/no-clobber "
                "protocol cannot repair a starter asset automatically and requires explicit "
                "maintainer recovery"
            )
        if asset.get("size") != expectation.size:
            raise PublicationError(
                f"GitHub release asset size mismatch for {name}: "
                f"actual={asset.get('size')!r} expected={expectation.size}"
            )
        api_url = asset.get("url")
        browser_url = asset.get("browser_download_url")
        if not isinstance(api_url, str) or not isinstance(browser_url, str):
            raise PublicationError(f"GitHub release asset {name} is missing download URLs")
        validate_download_url(api_url, expected_basename=None, api_only=True)
        validate_download_url(browser_url, expected_basename=name, api_only=False)
        remote.append(RemoteAsset(name, api_url, browser_url))
    expected_names = set(expectations)
    if not draft and seen != expected_names:
        raise PublicationError(
            "public GitHub release asset inventory mismatch: "
            f"missing={sorted(expected_names - seen) or 'none'}"
        )
    return ReleasePlan(
        release_id=release_id,
        state="draft" if draft else "public",
        remote_assets=tuple(remote),
        missing_assets=tuple(sorted(expected_names - seen)),
    )


def validate_download_url(url: str, expected_basename: str | None, *, api_only: bool) -> None:
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").casefold()
    if parsed.scheme != "https" or not host:
        raise PublicationError(f"download URL must use HTTPS: {url!r}")
    if host not in ALLOWED_DOWNLOAD_HOSTS and not host.endswith(".githubusercontent.com"):
        raise PublicationError(f"download URL uses an unreviewed host: {host!r}")
    if api_only and host != "api.github.com":
        raise PublicationError(f"authenticated asset URL must use api.github.com, got {host!r}")
    if expected_basename is not None:
        actual = urllib.parse.unquote(Path(parsed.path).name)
        if actual != expected_basename:
            raise PublicationError(
                f"download URL basename mismatch: actual={actual!r} expected={expected_basename!r}"
            )


def validate_candidate_manifest(
    context: dict[str, Any],
    manifest: dict[str, Any],
    appcast: str,
    expectations: dict[str, AssetExpectation],
) -> dict[str, Any]:
    normalized = rollout.validate_tip_manifest_appcast(context, manifest, appcast)
    release = context["release"]
    rollout_context = context["rollout"]
    application = context["applicationSigning"]
    expected_manifest_fields = {
        "sourceTag": release["tag"],
        "releaseCommit": release["commit"],
        "currentRole": rollout_context["role"],
        "signingIdentity": rollout_context["signingIdentity"],
        "bundleIdentifier": application["bundleIdentifier"],
        "teamIdentifier": application["teamIdentifier"],
        "marketingVersion": release["marketingVersion"],
        "buildNumber": release["buildNumber"],
        "migrationPhase": rollout_context["runtimeSecureStorageMigrationPhase"],
        "eligibilityProfile": rollout_context["eligibilityProfile"],
    }
    for key, expected in expected_manifest_fields.items():
        if normalized.get(key) != expected:
            raise PublicationError(
                f"published rollout manifest mismatch for {key}: "
                f"actual={normalized.get(key)!r} expected={expected!r}"
            )
    items = normalized["appcastItems"]
    newest = items[0]
    if newest.get("tag") != release["tag"] or newest.get("role") != rollout_context["role"]:
        raise PublicationError("published rollout manifest newest item differs from the candidate")
    artifact_manifests = [
        expectation
        for expectation in expectations.values()
        if expectation.name.endswith("-artifact-manifest.json")
    ]
    if len(artifact_manifests) != 1:
        raise PublicationError(
            "local Tip asset contract must contain exactly one app artifact manifest"
        )
    artifact_manifest = artifact_manifests[0]
    expected_artifact_manifest = {
        "name": artifact_manifest.name,
        "sha256": artifact_manifest.sha256,
    }
    if normalized.get("appArtifactManifest") != expected_artifact_manifest:
        raise PublicationError(
            "published rollout manifest appArtifactManifest differs from local exact bytes"
        )
    expected_suffix = ".pkg" if rollout_context["installationType"] == "package" else ".zip"
    enclosures = [
        expectation
        for expectation in expectations.values()
        if expectation.name.endswith(expected_suffix)
    ]
    if len(enclosures) != 1:
        raise PublicationError(
            f"local Tip asset contract must contain exactly one {expected_suffix} enclosure"
        )
    enclosure = enclosures[0]
    expected_enclosure = {
        "enclosureName": enclosure.name,
        "enclosureSize": enclosure.size,
        "enclosureSha256": enclosure.sha256,
    }
    actual_enclosure = {key: newest.get(key) for key in expected_enclosure}
    if actual_enclosure != expected_enclosure:
        raise PublicationError(
            "published rollout manifest newest enclosure differs from local exact bytes: "
            f"actual={actual_enclosure!r} expected={expected_enclosure!r}"
        )
    expected_predecessors = rollout_context["predecessors"]
    retained = items[1:]
    if len(retained) != len(expected_predecessors):
        raise PublicationError("published rollout manifest retained item count differs from context")
    for position, (item, predecessor) in enumerate(
        zip(retained, expected_predecessors), start=1
    ):
        actual = {
            "role": item.get("role"),
            "tag": item.get("tag"),
            "rolloutManifestSha256": item.get("rolloutManifestSha256"),
        }
        if actual != predecessor:
            raise PublicationError(
                f"published retained predecessor {position} differs from immutable context"
            )
    return normalized


def validate_local_candidate(
    context: dict[str, Any], expectations: dict[str, AssetExpectation]
) -> None:
    manifest = load_json_object(
        expectations["identity-rollout.json"].path, "local candidate rollout manifest"
    )
    try:
        appcast = expectations["appcast.xml"].path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise PublicationError(f"local candidate appcast is unreadable UTF-8: {error}") from error
    validate_candidate_manifest(context, manifest, appcast, expectations)


def retained_enclosure_expectations(
    context: dict[str, Any], manifest: dict[str, Any], appcast: str
) -> tuple[EnclosureExpectation, ...]:
    normalized = rollout.validate_tip_manifest_appcast(context, manifest, appcast)
    retained: list[EnclosureExpectation] = []
    for item in normalized["appcastItems"]:
        if item["role"] not in {"preparer", "transition"}:
            continue
        name = safe_basename(item["enclosureName"], "retained enclosure name")
        url = item["url"]
        validate_download_url(url, expected_basename=name, api_only=False)
        parsed = urllib.parse.urlparse(url)
        expected_fragment = (
            f"/{context['sparkle']['updateRepository']}/releases/download/"
            f"{item['tag']}/{name}"
        )
        if urllib.parse.unquote(parsed.path) != expected_fragment:
            raise PublicationError(
                f"retained {item['role']} enclosure URL path differs from its tag/name: {url}"
            )
        retained.append(
            EnclosureExpectation(
                role=item["role"],
                tag=item["tag"],
                name=name,
                url=url,
                size=item["enclosureSize"],
                sha256=item["enclosureSha256"],
            )
        )
    return tuple(retained)


def verify_context(args: argparse.Namespace) -> dict[str, Any]:
    verification = types.SimpleNamespace(
        context=args.context,
        digest=args.digest,
        stable_appcast=args.stable_appcast,
        expected_context_sha256=args.expected_context_sha256,
        expected_approved_source_commit=args.expected_approved_source_commit,
        expected_tooling_commit=args.expected_tooling_commit,
        boundary="tip-publication",
        approved_source_root=args.approved_source_root,
        trusted_tooling_root=args.trusted_tooling_root,
        expected_role=None,
        expected_installation_type=None,
        expected_tag=None,
        expected_build_number=None,
    )
    try:
        context, _digest, _elapsed = context_tool.verify_context(verification)
    except context_tool.TipReleaseContextError as error:
        raise PublicationError(f"immutable Tip context verification failed: {error}") from error
    expected_environment = context_tool.shell_exports(context, args.expected_context_sha256)
    for name, expected in expected_environment.items():
        if name in os.environ and os.environ[name] != expected:
            raise PublicationError(
                f"Ambient {name} conflicts with the verified Tip release context"
            )
    return context


@contextlib.contextmanager
def github_token_environment(token: str) -> Iterator[None]:
    previous = {name: os.environ.get(name) for name in ("GH_TOKEN", "GITHUB_TOKEN")}
    os.environ["GH_TOKEN"] = token
    os.environ.pop("GITHUB_TOKEN", None)
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


@contextlib.contextmanager
def anonymous_github_environment(token_env: str) -> Iterator[None]:
    names = (token_env, "GH_TOKEN", "GITHUB_TOKEN")
    previous = {name: os.environ.get(name) for name in names}
    for name in names:
        os.environ.pop(name, None)
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is not None:
                os.environ[name] = value


class PublicationRunner:
    def __init__(
        self,
        *,
        work_dir: Path,
        dist_dir: Path,
        total_asset_bytes: int,
        token_env: str,
        command_timeout: float,
        asset_timeout: float,
    ) -> None:
        for label, value in (
            ("publication command timeout", command_timeout),
            ("publication asset timeout", asset_timeout),
        ):
            if not math.isfinite(value) or value <= 0 or value > MAX_PUBLICATION_TIMEOUT_SECONDS:
                raise PublicationError(
                    f"{label} must be finite, positive, and no greater than "
                    f"{MAX_PUBLICATION_TIMEOUT_SECONDS:g} seconds"
                )
        self.work_dir = work_dir
        self.dist_dir = dist_dir
        self.total_asset_bytes = total_asset_bytes
        self.token_env = token_env
        self.command_timeout = command_timeout
        self.asset_timeout = asset_timeout

    def run_material(
        self,
        phase: str,
        command: list[str],
        *,
        timeout: float | None = None,
        payload_path: Path | None = None,
        payload_size: int = 0,
        authenticated: bool = False,
    ) -> None:
        capture = self.work_dir / f"supervisor-{uuid.uuid4().hex}.capture"
        values = types.SimpleNamespace(
            phase=phase,
            timeout_seconds=timeout or self.command_timeout,
            heartbeat_seconds=30.0,
            term_grace_seconds=2.0,
            kill_wait_seconds=2.0,
            capture_file=str(capture),
            cwd=str(self.work_dir),
            app_path=str(self.dist_dir),
            app_size_bytes=self.total_asset_bytes,
            payload_path=str(payload_path or self.dist_dir),
            payload_size_bytes=payload_size,
            redact_env=[self.token_env, "GH_TOKEN", "GITHUB_TOKEN"],
            emit_output_tail=False,
            output_tail_bytes=8192,
            notarytool_json_evidence=False,
            command=command,
        )
        token = os.environ.get(self.token_env, "")
        environment = (
            github_token_environment(token)
            if authenticated
            else anonymous_github_environment(self.token_env)
        )
        with environment:
            result = supervisor.run_supervised(values)
        if result != 0:
            raise PublicationError(
                f"bounded publication phase {phase!r} failed with exit status {result}"
            )

    def fetch_json(
        self,
        phase: str,
        url: str,
        *,
        authenticated: bool,
        allow_not_found: bool = False,
    ) -> dict[str, Any] | None:
        validate_download_url(url, expected_basename=None, api_only=url.startswith("https://api.github.com/"))
        output = self.work_dir / f"response-{uuid.uuid4().hex}.json"
        status = self.work_dir / f"status-{uuid.uuid4().hex}.txt"
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "_worker-http-get",
            "--url",
            url,
            "--output",
            str(output),
            "--status-output",
            str(status),
            "--maximum-bytes",
            str(MAX_JSON_BYTES),
        ]
        if authenticated:
            command += ["--token-env", self.token_env]
        if allow_not_found:
            command.append("--allow-not-found")
        self.run_material(
            phase,
            command,
            payload_path=output,
            authenticated=authenticated,
        )
        try:
            response_status = int(status.read_text(encoding="ascii").strip())
        except (OSError, ValueError) as error:
            raise PublicationError(f"publication HTTP phase did not record a valid status: {error}") from error
        if response_status == 404 and allow_not_found:
            return None
        if response_status != 200:
            raise PublicationError(f"publication HTTP phase returned status {response_status}")
        return load_json_object(output, f"{phase} response")

    def lookup_authenticated_release(
        self, phase: str, repository: str, tag: str
    ) -> dict[str, Any] | None:
        output = self.work_dir / f"release-lookup-{uuid.uuid4().hex}.json"
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "_worker-release-lookup",
            "--repository",
            repository,
            "--tag",
            tag,
            "--output",
            str(output),
            "--maximum-pages",
            str(MAX_RELEASE_LOOKUP_PAGES),
            "--token-env",
            self.token_env,
        ]
        self.run_material(
            phase,
            command,
            payload_path=output,
            authenticated=True,
        )
        envelope = load_json_object(output, f"{phase} response")
        if set(envelope) != {"release"}:
            raise PublicationError(f"{phase} response uses an unexpected schema")
        release = envelope["release"]
        if release is None:
            return None
        if not isinstance(release, dict):
            raise PublicationError(f"{phase} response release must be an object or null")
        return release

    def download(
        self,
        phase: str,
        url: str,
        destination: Path,
        expectation: AssetExpectation | EnclosureExpectation,
        *,
        authenticated: bool,
        api_asset: bool = False,
    ) -> None:
        validate_download_url(
            url,
            expected_basename=None if api_asset else expectation.name,
            api_only=api_asset,
        )
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "_worker-http-get",
            "--url",
            url,
            "--output",
            str(destination),
            "--status-output",
            str(destination) + ".status",
            "--maximum-bytes",
            str(expectation.size),
            "--expected-size",
            str(expectation.size),
            "--expected-sha256",
            expectation.sha256,
        ]
        if api_asset:
            command.append("--asset-api")
        if authenticated:
            command += ["--token-env", self.token_env]
        self.run_material(
            phase,
            command,
            timeout=self.asset_timeout,
            payload_path=destination,
            payload_size=expectation.size,
            authenticated=authenticated,
        )

    def gh(self, phase: str, arguments: list[str], *, payload_path: Path, payload_size: int) -> None:
        token = os.environ.get(self.token_env, "")
        if not token:
            raise PublicationError(f"missing required GitHub token environment: {self.token_env}")
        self.run_material(
            phase,
            ["gh", *arguments],
            payload_path=payload_path,
            payload_size=payload_size,
            authenticated=True,
        )


def _open_worker_file(path: Path):
    if path.exists() or path.is_symlink():
        raise PublicationError(f"HTTP worker refuses to replace output: {path}")
    return os.fdopen(
        os.open(
            path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
        ),
        "wb",
    )


def _write_worker_file(path: Path, value: bytes) -> None:
    with _open_worker_file(path) as handle:
        handle.write(value)


def _stream_worker_response(
    response: Any,
    output: Path,
    *,
    maximum_bytes: int,
    expected_size: int | None,
    expected_sha256: str | None,
) -> None:
    total = 0
    digest = hashlib.sha256()
    try:
        with _open_worker_file(output) as handle:
            while True:
                chunk = response.read(min(1024 * 1024, maximum_bytes - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum_bytes:
                    raise PublicationError(
                        f"HTTP response exceeded maximum byte count {maximum_bytes}"
                    )
                handle.write(chunk)
                digest.update(chunk)
            if expected_size is not None and total != expected_size:
                raise PublicationError(
                    f"HTTP response size mismatch: actual={total} expected={expected_size}"
                )
            if expected_sha256 is not None:
                actual_digest = digest.hexdigest()
                if actual_digest != expected_sha256:
                    raise PublicationError(
                        "HTTP response SHA-256 mismatch: "
                        f"actual={actual_digest} expected={expected_sha256}"
                    )
    except BaseException:
        try:
            output.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def run_worker_http_get(args: argparse.Namespace) -> int:
    validate_download_url(args.url, expected_basename=None, api_only=False)
    headers = {
        "Accept": "application/octet-stream" if args.asset_api else "application/vnd.github+json",
        "User-Agent": "RepoPrompt-CE-release-publication",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if args.token_env:
        token = os.environ.get(args.token_env, "")
        if not token:
            raise PublicationError(f"missing HTTP token environment {args.token_env}")
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(args.url, headers=headers, method="GET")
    status = 0
    output = Path(args.output)
    try:
        with GITHUB_URL_OPENER.open(request, timeout=30) as response:
            status = int(response.status)
            validate_download_url(response.geturl(), expected_basename=None, api_only=False)
            if status == 200:
                _stream_worker_response(
                    response,
                    output,
                    maximum_bytes=args.maximum_bytes,
                    expected_size=args.expected_size,
                    expected_sha256=args.expected_sha256,
                )
    except urllib.error.HTTPError as error:
        status = int(error.code)
        if status != 404 or not args.allow_not_found:
            raise PublicationError(f"HTTP GET failed with status {status}") from error
    except urllib.error.URLError as error:
        raise PublicationError(f"HTTP GET failed: {error.reason}") from error
    if status != 200 and (status != 404 or not args.allow_not_found):
        raise PublicationError(f"unexpected HTTP response status {status}")
    _write_worker_file(Path(args.status_output), f"{status}\n".encode("ascii"))
    return 0


def run_worker_release_lookup(args: argparse.Namespace) -> int:
    if SAFE_REPOSITORY.fullmatch(args.repository) is None:
        raise PublicationError(f"invalid release lookup repository: {args.repository!r}")
    safe_basename(args.tag, "release lookup tag")
    token = os.environ.get(args.token_env, "")
    if not token:
        raise PublicationError(f"missing HTTP token environment {args.token_env}")
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "RepoPrompt-CE-release-publication",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    matches: list[dict[str, Any]] = []
    for page in range(1, args.maximum_pages + 1):
        url = (
            f"https://api.github.com/repos/{args.repository}/releases"
            f"?per_page=100&page={page}"
        )
        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with GITHUB_URL_OPENER.open(request, timeout=30) as response:
                if int(response.status) != 200:
                    raise PublicationError(
                        f"authenticated release lookup returned status {response.status}"
                    )
                validate_download_url(response.geturl(), expected_basename=None, api_only=True)
                body = response.read(MAX_JSON_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise PublicationError(
                f"authenticated release lookup failed with status {error.code}"
            ) from error
        except urllib.error.URLError as error:
            raise PublicationError(
                f"authenticated release lookup failed: {error.reason}"
            ) from error
        if len(body) > MAX_JSON_BYTES:
            raise PublicationError("authenticated release lookup page exceeded byte limit")
        try:
            releases = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PublicationError(
                f"authenticated release lookup returned malformed JSON: {error}"
            ) from error
        if not isinstance(releases, list) or len(releases) > 100:
            raise PublicationError("authenticated release lookup page is malformed")
        for release in releases:
            if not isinstance(release, dict):
                raise PublicationError("authenticated release lookup entry must be an object")
            if release.get("tag_name") == args.tag:
                matches.append(release)
        if len(matches) > 1:
            raise PublicationError(
                f"authenticated release lookup found duplicate tag {args.tag}"
            )
        if len(releases) < 100:
            break
    else:
        raise PublicationError(
            "authenticated release lookup exceeded its bounded pagination limit"
        )
    _write_worker_file(
        Path(args.output),
        (json.dumps({"release": matches[0] if matches else None}, sort_keys=True) + "\n").encode(
            "utf-8"
        ),
    )
    return 0


def fetch_live_main(
    runner: PublicationRunner,
    expected: str,
    phase: str,
    *,
    repository: str = SOURCE_REPOSITORY,
) -> str:
    if repository != SOURCE_REPOSITORY:
        raise PublicationError(
            f"protected-main repository must remain {SOURCE_REPOSITORY}, got {repository!r}"
        )
    response = runner.fetch_json(
        phase,
        f"https://api.github.com/repos/{repository}/commits/main",
        authenticated=False,
    )
    if response is None:
        raise PublicationError("protected source main unexpectedly returned not found")
    commit = response.get("sha")
    if not isinstance(commit, str) or LOWER_COMMIT.fullmatch(commit) is None:
        raise PublicationError("protected source main response contains a malformed commit")
    if commit != expected:
        raise PublicationError(
            f"protected source main changed before publication: actual={commit} expected={expected}"
        )
    return commit


def fetch_release(
    runner: PublicationRunner,
    repository: str,
    tag: str,
    *,
    authenticated: bool,
    allow_not_found: bool,
    phase: str,
) -> dict[str, Any] | None:
    if authenticated:
        release = runner.lookup_authenticated_release(phase, repository, tag)
        if release is None and not allow_not_found:
            raise PublicationError(f"{phase} did not find release tag {tag}")
        return release
    encoded_tag = urllib.parse.quote(tag, safe="")
    return runner.fetch_json(
        phase,
        f"https://api.github.com/repos/{repository}/releases/tags/{encoded_tag}",
        authenticated=authenticated,
        allow_not_found=allow_not_found,
    )


def fetch_live_rollout(
    runner: PublicationRunner, repository: str, directory: Path, phase_prefix: str
) -> tuple[dict[str, Any], str, bytes, bytes]:
    directory.mkdir()
    manifest_path = directory / "identity-rollout.json"
    appcast_path = directory / "appcast.xml"
    for name, path in (("identity-rollout.json", manifest_path), ("appcast.xml", appcast_path)):
        runner.run_material(
            f"{phase_prefix} {name} fetch",
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "_worker-http-get",
                "--url",
                f"https://github.com/{repository}/releases/latest/download/{name}",
                "--output",
                str(path),
                "--status-output",
                str(path) + ".status",
                "--maximum-bytes",
                str(MAX_JSON_BYTES),
            ],
            payload_path=path,
        )
    manifest_bytes = manifest_path.read_bytes()
    appcast_bytes = appcast_path.read_bytes()
    manifest = load_json_object(manifest_path, f"{phase_prefix} rollout manifest")
    try:
        appcast = appcast_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicationError(f"{phase_prefix} appcast is not UTF-8: {error}") from error
    return manifest, appcast, manifest_bytes, appcast_bytes


def audit_remote_release_assets(
    runner: PublicationRunner,
    plan: ReleasePlan,
    expectations: dict[str, AssetExpectation],
    directory: Path,
    *,
    authenticated: bool,
    phase_prefix: str,
) -> None:
    directory.mkdir()
    for asset in plan.remote_assets:
        expectation = expectations[asset.name]
        destination = directory / asset.name
        runner.download(
            f"{phase_prefix} asset {asset.name}",
            asset.api_url if authenticated else asset.browser_url,
            destination,
            expectation,
            authenticated=authenticated,
            api_asset=authenticated,
        )


def audit_retained_enclosures(
    runner: PublicationRunner,
    context: dict[str, Any],
    manifest: dict[str, Any],
    appcast: str,
    directory: Path,
    *,
    phase_prefix: str,
) -> None:
    directory.mkdir()
    expectations = retained_enclosure_expectations(context, manifest, appcast)
    for position, expectation in enumerate(expectations, start=1):
        destination = directory / f"{position}-{expectation.name}"
        runner.download(
            f"{phase_prefix} retained {expectation.role} {expectation.tag}",
            expectation.url,
            destination,
            expectation,
            authenticated=False,
        )


def validate_and_audit_live_predecessor(
    runner: PublicationRunner,
    context: dict[str, Any],
    manifest: dict[str, Any],
    appcast: str,
    manifest_bytes: bytes,
    directory: Path,
    *,
    phase_prefix: str,
) -> None:
    try:
        rollout.validate_live_tip_publication_state(
            context,
            manifest,
            appcast,
            hashlib.sha256(manifest_bytes).hexdigest(),
            context["release"]["commit"],
        )
    except rollout.RolloutError as error:
        raise PublicationError(f"live Tip predecessor state is unsafe: {error}") from error
    audit_retained_enclosures(
        runner,
        context,
        manifest,
        appcast,
        directory,
        phase_prefix=phase_prefix,
    )


def create_draft(
    runner: PublicationRunner, context: dict[str, Any], work_dir: Path
) -> None:
    publication = context["publication"]
    request = work_dir / "create-draft.json"
    write_private_json(
        request,
        {
            "tag_name": context["release"]["tag"],
            "target_commitish": publication["target"],
            "name": expected_release_title(context),
            "body": expected_release_notes(context),
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
        },
    )
    runner.gh(
        "draft release creation",
        [
            "api",
            "--method",
            "POST",
            f"repos/{publication['repository']}/releases",
            "--input",
            str(request),
        ],
        payload_path=request,
        payload_size=request.stat().st_size,
    )


def upload_missing_assets(
    runner: PublicationRunner,
    context: dict[str, Any],
    plan: ReleasePlan,
    expectations: dict[str, AssetExpectation],
) -> None:
    repository = context["publication"]["repository"]
    tag = context["release"]["tag"]
    for name in plan.missing_assets:
        expectation = expectations[name]
        runner.gh(
            f"draft asset upload {name}",
            ["release", "upload", tag, str(expectation.path), "--repo", repository],
            payload_path=expectation.path,
            payload_size=expectation.size,
        )


def publish_draft(
    runner: PublicationRunner,
    context: dict[str, Any],
    release_id: int,
    work_dir: Path,
) -> None:
    request = work_dir / "publish-draft.json"
    write_private_json(request, {"draft": False, "make_latest": "true"})
    runner.gh(
        "audited draft publication",
        [
            "api",
            "--method",
            "PATCH",
            f"repos/{context['publication']['repository']}/releases/{release_id}",
            "--input",
            str(request),
        ],
        payload_path=request,
        payload_size=request.stat().st_size,
    )


def anonymous_post_publish_audit(
    runner: PublicationRunner,
    context: dict[str, Any],
    expectations: dict[str, AssetExpectation],
    work_dir: Path,
) -> None:
    repository = context["publication"]["repository"]
    tag = context["release"]["tag"]
    release = fetch_release(
        runner,
        repository,
        tag,
        authenticated=False,
        allow_not_found=False,
        phase="anonymous public release lookup",
    )
    if release is None:
        raise PublicationError("published Tip release is not anonymously reachable")
    plan = validate_release_metadata(context, release, expectations)
    if plan.state != "public" or plan.missing_assets:
        raise PublicationError("anonymous post-publication release is not complete and public")
    audit_remote_release_assets(
        runner,
        plan,
        expectations,
        work_dir / "anonymous-assets",
        authenticated=False,
        phase_prefix="anonymous post-publication",
    )
    manifest, appcast, manifest_bytes, appcast_bytes = fetch_live_rollout(
        runner, repository, work_dir / "anonymous-live", "anonymous latest"
    )
    if hashlib.sha256(manifest_bytes).hexdigest() != expectations["identity-rollout.json"].sha256:
        raise PublicationError("anonymous latest rollout manifest differs from published candidate bytes")
    if hashlib.sha256(appcast_bytes).hexdigest() != expectations["appcast.xml"].sha256:
        raise PublicationError("anonymous latest appcast differs from published candidate bytes")
    validate_candidate_manifest(context, manifest, appcast, expectations)
    audit_retained_enclosures(
        runner,
        context,
        manifest,
        appcast,
        work_dir / "anonymous-retained",
        phase_prefix="anonymous post-publication",
    )


def run_publish(args: argparse.Namespace) -> int:
    dist_dir = preflight_local_inputs(args)
    context = verify_context(args)
    repository = context["publication"]["repository"]
    if SAFE_REPOSITORY.fullmatch(repository) is None:
        raise PublicationError(f"invalid Tip publication repository: {repository!r}")
    expectations, _checksums_sha256 = build_local_asset_expectations(
        context,
        dist_dir,
        Path(args.context),
        Path(args.digest),
        args.expected_sha256sums_sha256,
    )
    validate_local_candidate(context, expectations)
    token = os.environ.get(args.token_env, "")
    if not token:
        raise PublicationError(f"missing required GitHub token environment: {args.token_env}")
    total_bytes = sum(expectation.size for expectation in expectations.values())
    work_root = Path(tempfile.mkdtemp(prefix="repoprompt-tip-publication-"))
    try:
        runner = PublicationRunner(
            work_dir=work_root,
            dist_dir=dist_dir,
            total_asset_bytes=total_bytes,
            token_env=args.token_env,
            command_timeout=args.command_timeout_seconds,
            asset_timeout=args.asset_timeout_seconds,
        )
        started = phase_start(
            "Tip publication protocol",
            role=context["rollout"]["role"],
            tag=context["release"]["tag"],
            context=args.expected_context_sha256,
        )
        fetch_live_main(
            runner,
            context["release"]["commit"],
            "protected source main pre-publication verification",
        )
        release = fetch_release(
            runner,
            repository,
            context["release"]["tag"],
            authenticated=True,
            allow_not_found=True,
            phase="authenticated candidate release lookup",
        )
        plan = validate_release_metadata(context, release, expectations) if release else None
        live_manifest, live_appcast, live_manifest_bytes, live_appcast_bytes = fetch_live_rollout(
            runner, repository, work_root / "pre-publication-live", "pre-publication latest"
        )

        if plan is not None and plan.state == "public":
            if plan.missing_assets:
                raise PublicationError("existing public Tip release is missing expected assets")
            audit_remote_release_assets(
                runner,
                plan,
                expectations,
                work_root / "authenticated-public-assets",
                authenticated=True,
                phase_prefix="authenticated existing public",
            )
            if (
                hashlib.sha256(live_manifest_bytes).hexdigest()
                != expectations["identity-rollout.json"].sha256
            ):
                raise PublicationError("existing public release is not the exact live rollout manifest")
            if (
                hashlib.sha256(live_appcast_bytes).hexdigest()
                != expectations["appcast.xml"].sha256
            ):
                raise PublicationError("existing public release is not the exact live appcast")
            validate_candidate_manifest(context, live_manifest, live_appcast, expectations)
            audit_retained_enclosures(
                runner,
                context,
                live_manifest,
                live_appcast,
                work_root / "authenticated-public-retained",
                phase_prefix="authenticated existing public",
            )
            anonymous_post_publish_audit(runner, context, expectations, work_root)
            phase_complete("Tip publication protocol", started, result="existing-public-audited")
            return 0

        validate_and_audit_live_predecessor(
            runner,
            context,
            live_manifest,
            live_appcast,
            live_manifest_bytes,
            work_root / "pre-publication-retained",
            phase_prefix="pre-publication",
        )

        if release is None:
            create_draft(runner, context, work_root)
            release = fetch_release(
                runner,
                repository,
                context["release"]["tag"],
                authenticated=True,
                allow_not_found=False,
                phase="created draft lookup",
            )
            if release is None:
                raise PublicationError("created draft release is not authenticated-reachable")
            plan = validate_release_metadata(context, release, expectations)
        assert plan is not None
        if plan.state != "draft":
            raise PublicationError("candidate release changed state unexpectedly before draft audit")
        audit_remote_release_assets(
            runner,
            plan,
            expectations,
            work_root / "resumed-draft-assets",
            authenticated=True,
            phase_prefix="resumed draft",
        )
        upload_missing_assets(runner, context, plan, expectations)
        release = fetch_release(
            runner,
            repository,
            context["release"]["tag"],
            authenticated=True,
            allow_not_found=False,
            phase="complete draft lookup",
        )
        if release is None:
            raise PublicationError("completed draft release disappeared")
        complete_plan = validate_release_metadata(context, release, expectations)
        if complete_plan.state != "draft" or complete_plan.missing_assets:
            raise PublicationError("draft asset upload did not produce one exact complete draft")
        audit_remote_release_assets(
            runner,
            complete_plan,
            expectations,
            work_root / "complete-draft-assets",
            authenticated=True,
            phase_prefix="complete draft",
        )
        fetch_live_main(
            runner,
            context["release"]["commit"],
            "protected source main final publication verification",
        )
        (
            final_live_manifest,
            final_live_appcast,
            final_live_manifest_bytes,
            _final_live_appcast_bytes,
        ) = fetch_live_rollout(
            runner,
            repository,
            work_root / "final-pre-publication-live",
            "final pre-publication latest",
        )
        validate_and_audit_live_predecessor(
            runner,
            context,
            final_live_manifest,
            final_live_appcast,
            final_live_manifest_bytes,
            work_root / "final-pre-publication-retained",
            phase_prefix="final pre-publication",
        )
        publish_draft(runner, context, complete_plan.release_id, work_root)
        anonymous_post_publish_audit(runner, context, expectations, work_root)
        phase_complete("Tip publication protocol", started, result="published-and-audited")
        return 0
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def positive_float(value: str) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    if result > MAX_PUBLICATION_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(
            f"must not exceed {MAX_PUBLICATION_TIMEOUT_SECONDS:g} seconds"
        )
    return result


def nonnegative_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if result < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    provenance = commands.add_parser("validate-provenance")
    provenance.add_argument("--workflow-definition-commit", required=True)
    provenance.add_argument("--tooling-commit", required=True)
    provenance.add_argument("--selected-source-commit", required=True)
    provenance.add_argument("--repository", default=SOURCE_REPOSITORY)
    provenance.add_argument("--trusted-tooling-root", required=True)
    provenance.add_argument(
        "--command-timeout-seconds", type=positive_float, default=120.0
    )
    provenance.set_defaults(func=run_validate_provenance)

    def add_local_asset_arguments(command: argparse.ArgumentParser) -> None:
        command.add_argument("--context", required=True)
        command.add_argument("--digest", required=True)
        command.add_argument("--stable-appcast", required=True)
        command.add_argument("--expected-context-sha256", required=True)
        command.add_argument("--expected-approved-source-commit", required=True)
        command.add_argument("--expected-tooling-commit", required=True)
        command.add_argument("--approved-source-root", required=True)
        command.add_argument("--trusted-tooling-root", required=True)
        command.add_argument("--dist-dir", required=True)

    validate_local = commands.add_parser("validate-local-assets")
    add_local_asset_arguments(validate_local)
    validate_local.add_argument("--expected-sha256sums-sha256")
    validate_local.add_argument("--github-output")
    validate_local.set_defaults(func=run_validate_local_assets)

    publish = commands.add_parser("publish")
    add_local_asset_arguments(publish)
    publish.add_argument("--expected-sha256sums-sha256", required=True)
    publish.add_argument("--token-env", default="TIP_GH_TOKEN")
    publish.add_argument(
        "--command-timeout-seconds", type=positive_float, default=DEFAULT_COMMAND_TIMEOUT_SECONDS
    )
    publish.add_argument(
        "--asset-timeout-seconds", type=positive_float, default=DEFAULT_ASSET_TIMEOUT_SECONDS
    )
    publish.set_defaults(func=run_publish)

    worker = commands.add_parser("_worker-http-get")
    worker.add_argument("--url", required=True)
    worker.add_argument("--output", required=True)
    worker.add_argument("--status-output", required=True)
    worker.add_argument("--maximum-bytes", required=True, type=nonnegative_int)
    worker.add_argument("--expected-size", type=nonnegative_int)
    worker.add_argument("--expected-sha256")
    worker.add_argument("--token-env")
    worker.add_argument("--allow-not-found", action="store_true")
    worker.add_argument("--asset-api", action="store_true")
    worker.set_defaults(func=run_worker_http_get)

    release_lookup = commands.add_parser("_worker-release-lookup")
    release_lookup.add_argument("--repository", required=True)
    release_lookup.add_argument("--tag", required=True)
    release_lookup.add_argument("--output", required=True)
    release_lookup.add_argument("--maximum-pages", required=True, type=nonnegative_int)
    release_lookup.add_argument("--token-env", required=True)
    release_lookup.set_defaults(func=run_worker_release_lookup)
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (PublicationError, rollout.RolloutError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
