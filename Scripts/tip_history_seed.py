#!/usr/bin/env python3
"""Audited Tip history seed-bootstrap evidence (tip-build-rollback plan §3.3).

Produces the bootstrap evidence consumed by ``tip_history_admission.build_payload``:
up to 29 admitted predecessors of an explicit candidate, ordered by validated
numeric build. Every seed is re-verified from its own published assets:
release record and exact inventory, SHA256SUMS consistency, rollout manifest
and appcast (via ``stable_rollout``), artifact manifest and metadata bindings,
source floor/ancestry, enclosure size/SHA-256/Sparkle EdDSA with the pinned key,
and, for application archives, layout/expanded-size preflight, extraction into
an owned temporary directory, bundle/executable digests, strict all-architecture
nested code signing against the committed Developer ID requirement, and a
Gatekeeper assessment. Package (transition) seeds remain non-downloadable but
must pass the same provenance plus installer signature/notarization checks.

What this tool deliberately does NOT do:
- it never executes obtained apps, installs packages or writes /Applications;
- it never signs, publishes or mutates GitHub; no tokens are sent;
- it never invents review authority. Retention/immutability review, the
  admission-floor source audit, the activation tag and per-interval persistence
  verdicts remain external inputs. Seeds without a bound persistence verdict get
  a blocking downgrade barrier; uncertain releases are excluded and reported as
  a shortfall instead of being fabricated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import unicodedata
import urllib.request
import zlib
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Callable, Optional

sys.dont_write_bytecode = True
import stable_rollout as rollout  # noqa: E402
import tip_history as history  # noqa: E402
import tip_history_admission as admission  # noqa: E402

SCRIPTS_DIR = Path(__file__).resolve().parent
VERIFY_SPARKLE_SCRIPT = SCRIPTS_DIR / "verify_sparkle_signature.swift"
DEFAULT_APPLE_POLICY = SCRIPTS_DIR / "apple_identity_policy.json"

EVIDENCE_SCHEMA_VERSION = 1
REQUIRED_SEEDS = history.WINDOW - 1
ROLLOUT_NAME = "identity-rollout.json"
APPCAST_NAME = "appcast.xml"
SUMS_NAME = "SHA256SUMS"
HISTORY_ASSET = "tip-history.json"
MIB = 1024 * 1024
SMALL_ASSET_LIMIT = 4 * MIB
RELEASES_JSON_LIMIT = 64 * MIB
ENCLOSURE_LIMIT = 2 * 1024**3
EXPANDED_LIMIT = 8 * 1024**3
ZIP_ENTRY_LIMIT = 100_000
SYMLINK_TARGET_LIMIT = 4096
SYMLINK_COMPRESSED_LIMIT = 65536
CENTRAL_DIRECTORY_LIMIT = 32 * MIB
EOCD_SEARCH_LIMIT = 65557
PATH_BYTE_LIMIT = 1024
PATH_PART_LIMIT = 128
LINK_EXPANSION_LIMIT = 40
RESOLUTION_LIMIT = 4096
INFLATE_CHUNK = 65536
# General-purpose flags: bits 1-2 (deflate options), 3 (data descriptor), 11 (UTF-8).
ALLOWED_ZIP_FLAGS = 0x080E
NOTARIZED_AUTHORITY = "Notarized Developer ID"
PLIST_LIMIT = MIB
EXTRACTION_HEADROOM = 64 * MIB
UNIVERSAL = frozenset({"arm64", "x86_64"})
NOTARIZED_SOURCE = "source=Notarized Developer ID"
REDIRECT_HOSTS = frozenset({"release-assets.githubusercontent.com"})
SNAPSHOT_MARKER = ".tip-history-seed-snapshot"
PERSISTENCE_PENDING = "Seed persistence audit pending; downgrade safety unknown"
PERSISTENCE_VERDICTS = ("no-known-downgrade-break", "downgrade-break")
# Review hints only: changed paths that commonly carry persisted formats or
# update-preference semantics. Absence of a hint is never treated as safety.
PERSISTENCE_HINT_PATHS = (
    "AppBundle/",
    "Sources/RepoPrompt/App/Sparkle/",
    "Sources/RepoPrompt/Features/Settings/",
    "Sources/RepoPrompt/Infrastructure/Persistence/",
    "Sources/RepoPromptPersistence/",
    "Sources/RepoPromptSecureStorage/",
    "Sources/RepoPromptSettingsCore/",
    "Sources/RepoPromptWorkspaceCore/",
)
HINT_LIMIT = 50
TOOL_TIMEOUT = 600
ALLOWED_TOOLS = frozenset({
    "/usr/bin/codesign",
    "/usr/bin/ditto",
    "/usr/bin/lipo",
    "/usr/bin/xcrun",
    "/usr/sbin/pkgutil",
    "/usr/sbin/spctl",
})
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,199}\Z")
SUMS_LINE = re.compile(r"([0-9a-f]{64})  ([^/\s][^/]*)\Z")
EXTERNAL_REVIEW_GATES = (
    "Retention/immutability of the Tip update repository requires maintainer review (policy retention); release 'immutable' flags are observations, not proof of a no-deletion guarantee.",
    "Admission floor build/commit (passive-only update checks, force-Sparkle-off, committed bridge activation) is reviewed policy input; this tool enforces it but does not prove it.",
    "historyEnabledSinceTag and bootstrapEvidenceSha256 must be pinned by reviewed policy after this evidence is reviewed.",
    "Per-seed persistence/downgrade audit verdicts are external review input (--source-audit); missing verdicts keep blocking barriers.",
    "Disposable-VM manual migration/reinstall/Keychain/preference checks (plan §6.2) are not performed by this tool.",
    "DMG assets are inventory/checksum-listed only; they are not catalog download targets and are not fetched or audited.",
    "Gatekeeper assessment reflects Apple notarization/revocation state at audit time on the auditing Mac.",
)


class SeedExclusion(history.HistoryError):
    """A release cannot be admitted; recorded with a reason, never fatal."""


class AuditEnvironmentError(RuntimeError):
    """Environment problem (network, disk, missing tool); the run aborts."""


# Malformed published data excludes that release (with a recorded reason);
# environment failures (AuditEnvironmentError, timeouts) abort the whole run.
RELEASE_DATA_ERRORS = (rollout.RolloutError, ValueError, KeyError, TypeError, AttributeError)


Runner = Callable[[list, int], subprocess.CompletedProcess]
Verifier = Callable[[str, str, Path], bool]
Fetcher = Callable[[str, Path, int], None]


def exclude_unless(condition: bool, message: str) -> None:
    if not condition:
        raise SeedExclusion(message)


# --------------------------------------------------------------------------
# Tool execution and signature verification (dependency-injectable)
# --------------------------------------------------------------------------

def _tool_environment() -> dict:
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"}
    for key in ("HOME", "TMPDIR", "DEVELOPER_DIR"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    return env


def run_tool(argv: list, timeout: int) -> subprocess.CompletedProcess:
    """Run an allow-listed system inspection tool. Never runs obtained code."""
    argv = [str(value) for value in argv]
    history.require(bool(argv) and argv[0] in ALLOWED_TOOLS, f"refusing to run non-allow-listed executable: {argv[:1]}")
    if argv[0] == "/usr/bin/xcrun":
        history.require(
            len(argv) >= 3 and (argv[1:3] == ["swift", str(VERIFY_SPARKLE_SCRIPT)] or argv[1:3] == ["stapler", "validate"]),
            "xcrun is limited to the trusted Sparkle verifier and stapler validation",
        )
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=_tool_environment(), stdin=subprocess.DEVNULL, check=False)
    except FileNotFoundError as error:
        raise AuditEnvironmentError(f"required tool unavailable: {argv[0]}") from error


def trusted_sparkle_verifier(runner: Runner) -> Verifier:
    """Ed25519 via the committed read-only verify_sparkle_signature.swift."""
    def verify(public_key: str, signature: str, path: Path) -> bool:
        history.decode64(public_key, 32)
        history.decode64(signature, 64)
        history.require(VERIFY_SPARKLE_SCRIPT.is_file(), "trusted Sparkle verifier script is missing")
        with tempfile.TemporaryDirectory(prefix="tip-history-seed-key-") as directory:
            key_path = Path(directory) / "public-key"
            key_path.write_text(public_key + "\n", encoding="utf-8")
            result = runner(["/usr/bin/xcrun", "swift", str(VERIFY_SPARKLE_SCRIPT), str(key_path), signature, str(path)], TOOL_TIMEOUT)
        return result.returncode == 0
    return verify


# --------------------------------------------------------------------------
# Bounded official-URL fetching
# --------------------------------------------------------------------------

def check_official_url(url: str, repository: str, tag: str, name: str) -> None:
    history.require(url == rollout.enclosure_url(repository, tag, name), "fetch URL is not the exact official release download URL")
    parsed = urllib.parse.urlsplit(url)
    history.require(parsed.scheme == "https" and parsed.hostname == "github.com" and parsed.port is None and parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment, "fetch URL must be plain https://github.com")


def check_redirect_url(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    history.require(
        parsed.scheme == "https" and parsed.hostname in REDIRECT_HOSTS and parsed.port is None
        and parsed.username is None and parsed.password is None and parsed.netloc == parsed.hostname,
        f"redirect to a non-allow-listed destination: {parsed.scheme}://{parsed.hostname}",
    )


class _RestrictedRedirectHandler(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_redirect_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class BoundedFetcher:
    """Anonymous, size-exact, file-backed downloads with a restricted redirect policy."""

    def __init__(self, opener=None, timeout: int = 30, chunk: int = MIB):
        self.opener = opener or urllib.request.build_opener(_RestrictedRedirectHandler)
        self.timeout = timeout
        self.chunk = chunk

    def __call__(self, url: str, destination: Path, exact_size: int) -> None:
        history.require(type(exact_size) is int and 0 < exact_size <= ENCLOSURE_LIMIT, "invalid declared asset size")
        history.require(not os.path.lexists(destination), "fetch destination already exists")
        partial = destination.with_name(f".{destination.name}.{os.getpid()}.{secrets.token_hex(6)}.partial")
        request = urllib.request.Request(url, headers={"User-Agent": "repoprompt-tip-history-seed", "Accept": "application/octet-stream"})
        try:
            try:
                response = self.opener.open(request, timeout=self.timeout)
            except urllib.error.HTTPError as error:
                raise AuditEnvironmentError(f"asset download HTTP {error.code}") from error
            except (urllib.error.URLError, OSError) as error:
                raise AuditEnvironmentError(f"asset download failed: {getattr(error, 'reason', error)}") from error
            with response:
                final = response.geturl()
                if final != url:
                    check_redirect_url(final)
                status = getattr(response, "status", None) or response.getcode()
                history.require(status == 200, f"asset download HTTP {status}")
                declared = response.headers.get("Content-Length") if response.headers is not None else None
                if declared is not None:
                    exclude_unless(declared.strip().isdigit() and int(declared) == exact_size, "asset Content-Length differs from the release record size")
                received = 0
                with open(partial, "xb") as output:
                    while True:
                        block = response.read(self.chunk)
                        if not block:
                            break
                        received += len(block)
                        exclude_unless(received <= exact_size, "asset download exceeded the release record size")
                        output.write(block)
            exclude_unless(received == exact_size, "asset download is shorter than the release record size")
            history.require(not os.path.lexists(destination), "fetch destination appeared during download")
            os.rename(partial, destination)
        finally:
            if os.path.lexists(partial):
                partial.unlink()


# --------------------------------------------------------------------------
# Release snapshot
# --------------------------------------------------------------------------

def _parse_json_any(data: bytes):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            history.require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid_constant(value):
        raise history.HistoryError(f"non-JSON numeric constant: {value}")

    return json.loads(data, object_pairs_hook=unique, parse_constant=invalid_constant)


@dataclass
class Release:
    tag: str
    draft: bool
    published: bool
    immutable: object
    assets: dict
    asset_problem: Optional[str] = None
    manifest: Optional[dict] = None
    build: Optional[tuple] = None
    manifest_path: Optional[Path] = None


def _release_from_record(record: object) -> Release:
    history.require(isinstance(record, dict) and isinstance(record.get("tag_name"), str), "malformed release record")
    assets = {}
    problem = None
    raw_assets = record.get("assets")
    if not isinstance(raw_assets, list):
        raw_assets, problem = [], "release record lacks an asset list"
    for asset in raw_assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            problem = "release record has a malformed asset"
            continue
        if asset["name"] in assets:
            problem = f"release record lists duplicate asset {asset['name']}"
        assets[asset["name"]] = asset
    published_at = record.get("published_at")
    return Release(
        tag=record["tag_name"],
        draft=record.get("draft") is not False,
        published=isinstance(published_at, str) and bool(published_at),
        immutable=record.get("immutable"),
        assets=assets,
        asset_problem=problem,
    )


class Snapshot:
    """``releases.json`` (gh api --paginate --slurp) plus ``assets/<tag>/<name>``.

    Pre-downloaded files are untrusted data and are verified exactly like
    fetched files. With a fetcher, missing assets are downloaded into this
    tool-owned cache (marked by ``.tip-history-seed-snapshot``).
    """

    def __init__(self, root: Path, repository: str, fetcher: Optional[Fetcher] = None):
        history.require(root.is_dir() and not root.is_symlink(), "release snapshot must be a real directory")
        self.root = root
        self.repository = repository
        self.fetcher = fetcher
        self.assets_root = root / "assets"
        releases = root / "releases.json"
        history.require(releases.is_file() and not releases.is_symlink() and releases.stat().st_size <= RELEASES_JSON_LIMIT, "release snapshot requires a bounded regular releases.json")
        self.releases_bytes = releases.read_bytes()
        if fetcher is not None:
            marker = root / SNAPSHOT_MARKER
            if not marker.exists():
                history.require(not os.path.lexists(self.assets_root), "refusing to fetch into an assets directory not owned by this tool")
                marker.write_text("tip_history_seed asset cache\n", encoding="utf-8")
            history.require(marker.is_file() and not marker.is_symlink(), "invalid snapshot ownership marker")

    @property
    def releases_sha256(self) -> str:
        return hashlib.sha256(self.releases_bytes).hexdigest()

    def records(self) -> list:
        data = _parse_json_any(self.releases_bytes)
        history.require(isinstance(data, list), "releases.json must be a JSON array")
        if data and all(isinstance(page, list) for page in data):
            data = [record for page in data for record in page]
        return data

    def _directory(self, path: Path, create: bool) -> None:
        if os.path.lexists(path):
            history.require(path.is_dir() and not path.is_symlink(), f"snapshot path is not a real directory: {path.name}")
        elif create:
            path.mkdir(mode=0o755)
            history.require(path.is_dir() and not path.is_symlink(), "snapshot directory creation raced")

    def asset(self, release: Release, name: str, limit: int) -> Path:
        tag = release.tag
        exclude_unless(history.TAG.fullmatch(tag) is not None and SAFE_COMPONENT.fullmatch(name) is not None, f"unsafe release asset name {name!r}")
        record = release.assets.get(name)
        exclude_unless(record is not None, f"release lacks asset {name}")
        exclude_unless(record.get("state") == "uploaded", f"asset {name} is not in the uploaded state")
        size = record.get("size")
        exclude_unless(type(size) is int and 0 < size <= limit, f"asset {name} size is missing or out of bounds")
        official = rollout.enclosure_url(self.repository, tag, name)
        exclude_unless(record.get("browser_download_url") == official, f"asset {name} download URL is not the exact official URL")
        create = self.fetcher is not None
        self._directory(self.assets_root, create)
        directory = self.assets_root / tag
        if os.path.lexists(self.assets_root):
            self._directory(directory, create)
        path = directory / name
        if os.path.lexists(path):
            info = os.lstat(path)
            exclude_unless(stat.S_ISREG(info.st_mode), f"snapshot asset {name} is not a regular non-symlink file")
            exclude_unless(info.st_size == size, f"snapshot asset {name} size differs from the release record")
            return path
        if self.fetcher is None:
            raise SeedExclusion(f"asset {name} is not in the release snapshot")
        check_official_url(official, self.repository, tag, name)
        self.fetcher(official, path, size)
        info = os.lstat(path)
        exclude_unless(stat.S_ISREG(info.st_mode) and info.st_size == size, f"fetched asset {name} size differs from the release record")
        return path


# --------------------------------------------------------------------------
# Archive and bundle audits
# --------------------------------------------------------------------------

def sha256_stream(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(MIB), b""):
            digest.update(block)
    return digest.hexdigest()


def _bad_text(value: str) -> bool:
    # Matches Foundation CharacterSet.controlCharacters (Cc + Cf, incl. bidi controls).
    return any(unicodedata.category(c) in ("Cc", "Cf") for c in value)


def _u16(data: bytes, index: int) -> int:
    return int.from_bytes(data[index:index + 2], "little")


def _u32(data: bytes, index: int) -> int:
    return int.from_bytes(data[index:index + 4], "little")


def _read_exact(handle, count: int) -> bytes:
    data = handle.read(count)
    exclude_unless(len(data) == count, "ZIP structure is truncated")
    return data


def _canonical_path(path: str) -> str:
    return unicodedata.normalize("NFC", path).casefold()


def _validate_zip_extra(data: bytes) -> None:
    """Admit only timestamp/owner fields (TipHistoryArchive.validateExtra).

    Rejects path overrides, hard-link fields, alternate streams and ZIP64.
    """
    index = 0
    seen = set()
    while index < len(data):
        exclude_unless(index + 4 <= len(data), "ZIP extra field is truncated")
        kind, size = _u16(data, index), _u16(data, index + 2)
        exclude_unless(kind not in seen and index + 4 + size <= len(data), "ZIP extra field is duplicated or truncated")
        seen.add(kind)
        body = data[index + 4:index + 4 + size]
        if kind == 0x5855:
            ok = size in (8, 12)
        elif kind == 0x7855:
            ok = size in (0, 4)
        elif kind == 0x5455:
            ok = size in (1, 5, 9, 13) and body[0] & 0xF8 == 0
        elif kind == 0x7875:
            ok = size >= 3 and body[0] == 1
            uid = body[1] if ok else 0
            ok = ok and 0 < uid <= 8 and 2 + uid < size
            gid = body[2 + uid] if ok else 0
            ok = ok and 0 < gid <= 8 and size == 3 + uid + gid
        else:
            ok = False
        exclude_unless(ok, f"ZIP extra field 0x{kind:04x} is not admitted")
        index += 4 + size


def _inflate_exact(handle, compressed: int, expected: int, crc: int, *, keep: bool = False) -> bytes:
    """Count raw DEFLATE output into fixed chunks; never trust declared sizes."""
    exclude_unless(compressed > 0, "ZIP DEFLATE entry is empty")
    inflater = zlib.decompressobj(-15)
    remaining, produced, running = compressed, 0, 0
    kept = []
    data = b""
    try:
        while not inflater.eof:
            if not data and remaining:
                data = _read_exact(handle, min(remaining, INFLATE_CHUNK))
                remaining -= len(data)
            # Fixed output bound per call; pending output drains on empty input.
            output = inflater.decompress(data, INFLATE_CHUNK)
            tail = inflater.unconsumed_tail
            produced += len(output)
            exclude_unless(produced <= expected, "ZIP DEFLATE output exceeds the declared uncompressed size")
            running = zlib.crc32(output, running)
            if keep:
                kept.append(output)
            if not output and len(tail) == len(data) and not inflater.eof:
                break  # input exhausted before the stream ended (or no progress)
            data = tail
    except zlib.error as error:
        raise SeedExclusion("ZIP DEFLATE stream is corrupt") from error
    exclude_unless(inflater.eof, "ZIP DEFLATE stream does not end at its compressed size")
    exclude_unless(not data and not inflater.unused_data and remaining == 0, "ZIP DEFLATE stream has trailing bytes")
    exclude_unless(produced == expected, "ZIP DEFLATE output is shorter than the declared uncompressed size")
    exclude_unless(running == crc, "ZIP entry CRC-32 mismatch")
    return b"".join(kept)


def _stored_exact(handle, size: int, crc: int, *, keep: bool = False) -> bytes:
    remaining, running = size, 0
    kept = []
    while remaining:
        data = _read_exact(handle, min(remaining, INFLATE_CHUNK))
        remaining -= len(data)
        running = zlib.crc32(data, running)
        if keep:
            kept.append(data)
    exclude_unless(running == crc, "ZIP entry CRC-32 mismatch")
    return b"".join(kept)


@dataclass
class _ZipRecord:
    path: str
    parts: list
    size: int
    compressed: int
    method: int
    flags: int
    crc: int
    local_offset: int
    is_link: bool
    is_directory: bool


def _resolve_zip_path(original: list, links: dict, app_name: str) -> list:
    """Resolve through the complete symlink graph (TipHistoryArchive.validateResolution)."""
    pending = list(original)
    resolved = []
    expansions = 0
    while pending:
        exclude_unless(len(pending) + len(resolved) <= RESOLUTION_LIMIT, "ZIP symlink resolution exceeds bounds")
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            exclude_unless(len(resolved) > 1, "ZIP symlink resolution escapes the app bundle")
            resolved.pop()
            continue
        resolved.append(part)
        exclude_unless(len(resolved) <= PATH_PART_LIMIT, "ZIP symlink resolution exceeds depth bounds")
        target = links.get(_canonical_path("/".join(resolved)))
        if target is not None:
            expansions += 1
            exclude_unless(expansions <= LINK_EXPANSION_LIMIT, "ZIP symlink graph has a cycle or excessive chain")
            resolved.pop()
            pending = target.split("/") + pending
        exclude_unless(not resolved or resolved[0] == app_name, "ZIP symlink resolution escapes the app bundle")
    exclude_unless(bool(resolved) and resolved[0] == app_name and len(resolved) <= PATH_PART_LIMIT and len("/".join(resolved).encode()) <= PATH_BYTE_LIMIT, "ZIP symlink resolution escapes the app bundle")
    return resolved


def zip_preflight(path: Path, app_name: str) -> int:
    """Narrow ZIP admission before ditto sees any byte; returns expanded bytes.

    Port of TipHistoryArchive.validate: strict EOCD/central directory, no
    encryption/ZIP64/split archives/unknown extras, local headers agreeing with
    the central directory, non-overlapping data, actual DEFLATE output counted
    with exact size and CRC, and every path resolved through the full symlink
    graph with NFC/casefold alias, physical-alias and file-ancestor checks.
    The total equals main_tip_release.sh tip_history_archive_expanded_size.
    """
    info = os.lstat(path)
    exclude_unless(stat.S_ISREG(info.st_mode) and 22 <= info.st_size <= ENCLOSURE_LIMIT, "ZIP archive bounds invalid")
    with open(path, "rb") as handle:
        length = os.fstat(handle.fileno()).st_size
        tail_length = min(length, EOCD_SEARCH_LIMIT)
        handle.seek(length - tail_length)
        tail = _read_exact(handle, tail_length)
        end = None
        for index in range(len(tail) - 22, -1, -1):
            if _u32(tail, index) == 0x06054B50 and index + 22 + _u16(tail, index + 20) == len(tail):
                end = index
                break
        exclude_unless(end is not None and _u16(tail, end + 4) == 0 and _u16(tail, end + 6) == 0 and _u16(tail, end + 8) == _u16(tail, end + 10), "enclosure is not a readable single-disk ZIP archive")
        count, central_size, central_offset = _u16(tail, end + 10), _u32(tail, end + 12), _u32(tail, end + 16)
        end_offset = length - tail_length + end
        exclude_unless(0 < count < 0xFFFF and count <= ZIP_ENTRY_LIMIT and central_offset + central_size == end_offset and central_size <= CENTRAL_DIRECTORY_LIMIT, "ZIP central directory limits exceeded (ZIP64/split archives are not admitted)")
        handle.seek(central_offset)
        central = _read_exact(handle, central_size)
        position = 0
        total = 0
        records = []
        seen = set()
        for _ in range(count):
            exclude_unless(position + 46 <= len(central) and _u32(central, position) == 0x02014B50, "ZIP central directory record malformed")
            flags, method = _u16(central, position + 8), _u16(central, position + 10)
            crc, compressed, size = _u32(central, position + 16), _u32(central, position + 20), _u32(central, position + 24)
            name_length, extra_length, comment_length = _u16(central, position + 28), _u16(central, position + 30), _u16(central, position + 32)
            attributes, local_offset = _u32(central, position + 38), _u32(central, position + 42)
            following = position + 46 + name_length + extra_length + comment_length
            exclude_unless(following <= len(central) and name_length > 0, "ZIP central directory record malformed")
            exclude_unless(flags & ~ALLOWED_ZIP_FLAGS == 0, "ZIP entry uses encryption or unsupported flags")
            exclude_unless(method in (0, 8), "ZIP entry uses an unsupported compression method")
            exclude_unless(_u16(central, position + 34) == 0 and local_offset < central_offset and 0xFFFFFFFF not in (compressed, size), "ZIP entry uses split/ZIP64 layout")
            try:
                name = central[position + 46:position + 46 + name_length].decode("utf-8")
            except UnicodeDecodeError as error:
                raise SeedExclusion("ZIP path is not UTF-8") from error
            _validate_zip_extra(central[position + 46 + name_length:position + 46 + name_length + extra_length])
            directory = name.endswith("/")
            normalized = name[:-1] if directory else name
            exclude_unless(len(name.encode()) <= PATH_BYTE_LIMIT and not name.startswith("/") and "\\" not in name and not _bad_text(name), "ZIP layout is not the expected app")
            canonical = _canonical_path(normalized)
            exclude_unless(canonical not in seen, "ZIP contains duplicate or case/Unicode-aliased paths")
            seen.add(canonical)
            parts = normalized.split("/")
            exclude_unless(parts[0] == app_name and len(parts) <= PATH_PART_LIMIT and all(part not in ("", ".", "..") for part in parts) and (len(parts) > 1 or directory), "ZIP layout is not the expected app")
            mode = (attributes >> 16) & 0xF000
            exclude_unless(mode in (0, 0x8000, 0x4000, 0xA000), "ZIP entry has an unsupported file type")
            exclude_unless((mode != 0x4000 or directory) and (not directory or (mode in (0, 0x4000) and size == 0)), "ZIP directory entry is inconsistent")
            link = mode == 0xA000
            exclude_unless(not link or (not directory and 0 < size <= SYMLINK_TARGET_LIMIT and 0 < compressed <= SYMLINK_COMPRESSED_LIMIT), "ZIP symlink target bounds invalid")
            total += size
            exclude_unless(total <= EXPANDED_LIMIT, "ZIP expanded bounds invalid")
            records.append(_ZipRecord(normalized, parts, size, compressed, method, flags, crc, local_offset, link, directory))
            position = following
        exclude_unless(position == len(central), "ZIP central directory has trailing bytes")
        exclude_unless(0 < total, "ZIP expanded bounds invalid")

        files = {_canonical_path(r.path) for r in records if not r.is_directory and not r.is_link}
        links = {}
        ranges = []
        for record in records:
            for depth in range(1, len(record.parts)):
                exclude_unless(_canonical_path("/".join(record.parts[:depth])) not in files, "ZIP regular file is an ancestor of another path")
            handle.seek(record.local_offset)
            header = _read_exact(handle, 30)
            exclude_unless(_u32(header, 0) == 0x04034B50 and _u16(header, 8) == record.method and _u16(header, 6) == record.flags, "ZIP local header disagrees with the central directory")
            exclude_unless(record.flags & 8 != 0 or (_u32(header, 18) == record.compressed and _u32(header, 22) == record.size and _u32(header, 14) == record.crc), "ZIP local sizes disagree with the central directory")
            local_name = _read_exact(handle, _u16(header, 26))
            local_extra = _read_exact(handle, _u16(header, 28))
            _validate_zip_extra(local_extra)
            exclude_unless(local_name == (record.path + ("/" if record.is_directory else "")).encode(), "ZIP local path disagrees with the central directory")
            start = record.local_offset + 30 + len(local_name) + len(local_extra)
            finish = start + record.compressed
            exclude_unless(finish <= central_offset, "ZIP entry data overlaps the central directory")
            ranges.append((record.local_offset, finish))
            handle.seek(start)
            if record.method == 0:
                exclude_unless(record.compressed == record.size, "ZIP stored entry sizes disagree")
                data = _stored_exact(handle, record.size, record.crc, keep=record.is_link)
            else:
                data = _inflate_exact(handle, record.compressed, record.size, record.crc, keep=record.is_link)
            if record.is_link:
                try:
                    target = data.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise SeedExclusion("ZIP symlink target is not UTF-8") from error
                exclude_unless(len(data) == record.size and bool(target) and len(data) <= PATH_BYTE_LIMIT and not target.startswith("/") and "\\" not in target and not _bad_text(target), "ZIP contains an absolute or malformed symlink")
                links[_canonical_path(record.path)] = target
        ranges.sort()
        for earlier, later in zip(ranges, ranges[1:]):
            exclude_unless(earlier[1] <= later[0], "ZIP entries overlap")

        filesystem_paths = set()
        physical_files = set()
        for record in records:
            resolved = _resolve_zip_path(record.parts, links, app_name)
            for depth in range(1, len(resolved)):
                exclude_unless(_canonical_path("/".join(resolved[:depth])) not in files, "ZIP path resolves beneath a regular file")
            for candidate in (record.parts, resolved):
                for depth in range(1, len(candidate) + 1):
                    filesystem_paths.add(_canonical_path("/".join(candidate[:depth])))
            exclude_unless(len(filesystem_paths) <= ZIP_ENTRY_LIMIT, "ZIP filesystem path limit exceeded")
            if not record.is_directory and not record.is_link:
                physical = _canonical_path("/".join(resolved))
                exclude_unless(physical not in physical_files, "ZIP regular files alias the same physical path")
                physical_files.add(physical)
    return total


def parse_gatekeeper_assessment(output: str) -> None:
    """Mirror TipHistoryDownloader.validateAssessment over spctl --raw output.

    Exit status or text alone could accept a disabled assessment system or a
    local override rule; only an exact notarized verdict is admitted.
    """
    data = (output or "").encode("utf-8")
    exclude_unless(0 < len(data) <= MIB, "Gatekeeper raw assessment missing or oversized")
    try:
        value = plistlib.loads(data)
    except Exception as error:  # plistlib raises several unrelated types
        raise SeedExclusion("Gatekeeper raw assessment is not a property list") from error
    authority = value.get("assessment:authority") if isinstance(value, dict) else None
    exclude_unless(
        isinstance(value, dict) and value.get("assessment:verdict") is True and "assessment:error" not in value
        and isinstance(authority, dict) and authority.get("assessment:authority:source") == NOTARIZED_AUTHORITY
        and "assessment:authority:override" not in authority and "assessment:authority:weak" not in authority,
        "Gatekeeper assessment did not report an exact notarized Developer ID verdict",
    )


def measure_tree(app: Path) -> int:
    """Post-extraction byte count (main_tip_release.sh method) plus containment."""
    root = os.path.realpath(app)
    total = 0
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in files + dirs:
            path = os.path.join(directory, name)
            info = os.lstat(path)
            if stat.S_ISLNK(info.st_mode):
                exclude_unless(not os.path.isabs(os.readlink(path)), "extracted app contains an absolute symlink")
                resolved = os.path.realpath(path)
                exclude_unless(resolved == root or resolved.startswith(root + os.sep), "extracted symlink escapes the app bundle")
            elif name in files:
                exclude_unless(stat.S_ISREG(info.st_mode), "extracted app contains a special file")
        for name in files:
            total += os.lstat(os.path.join(directory, name)).st_size
        for name in dirs:
            path = os.path.join(directory, name)
            if os.path.islink(path):
                total += os.lstat(path).st_size
    return total


def _relative_bundle_path(app: Path, relative: object) -> Path:
    exclude_unless(isinstance(relative, str) and relative and not relative.startswith("/") and ".." not in PurePosixPath(relative).parts and "\\" not in relative and not _bad_text(relative), "artifact executable path is unsafe")
    path = app / relative
    info = os.lstat(path) if os.path.lexists(path) else None
    exclude_unless(info is not None and stat.S_ISREG(info.st_mode), f"artifact executable {relative} is missing from the app")
    return path


def _rmtree(path: Path) -> None:
    def make_writable(function, target, _):
        parent = os.path.dirname(target)
        if not os.path.islink(parent):
            os.chmod(parent, 0o700)
        if not os.path.islink(target) and os.path.isdir(target):
            os.chmod(target, 0o700)
        function(target)

    if os.path.lexists(path):
        shutil.rmtree(path, onerror=make_writable)


@dataclass
class AuditContext:
    source: Path
    policy: dict
    apple: dict
    snapshot: Snapshot
    candidate_tag: str
    candidate_commit: str
    candidate_build: str
    work_dir: Path
    run: Runner
    verify: Verifier

    @property
    def app_name(self) -> str:
        return self.apple["identityTransitionPackage"]["appBundleName"]

    def assess(self, target: Path, kind: str) -> None:
        result = self.run(["/usr/sbin/spctl", "--assess", "--type", kind, "--raw", "--ignore-cache", "--no-cache", str(target)], TOOL_TIMEOUT)
        exclude_unless(result.returncode == 0, "Gatekeeper assessment rejected the artifact")
        parse_gatekeeper_assessment(result.stdout)

    def owned_work(self) -> Path:
        self.work_dir.mkdir(parents=True, exist_ok=True)
        return Path(tempfile.mkdtemp(prefix="tip-history-seed-", dir=self.work_dir))

    def audit_bundle(self, app: Path, manifest: dict, head: dict, artifact: dict) -> list:
        info_path = app / "Contents" / "Info.plist"
        exclude_unless(os.path.lexists(info_path) and stat.S_ISREG(os.lstat(info_path).st_mode) and os.lstat(info_path).st_size <= PLIST_LIMIT, "app Info.plist missing or out of bounds")
        try:
            info = plistlib.loads(info_path.read_bytes())
        except Exception as error:  # plistlib raises several unrelated types
            raise SeedExclusion("app Info.plist is unreadable") from error
        exclude_unless(isinstance(info, dict), "app Info.plist is not a dictionary")
        exclude_unless(info.get("CFBundleIdentifier") == manifest["bundleIdentifier"], "app bundle identifier differs from the rollout manifest")
        exclude_unless(info.get("CFBundleShortVersionString") == manifest["marketingVersion"], "app marketing version differs from the rollout manifest")
        exclude_unless(info.get("CFBundleVersion") == manifest["buildNumber"], "app build number differs from the rollout manifest")
        minimum = info.get("LSMinimumSystemVersion")
        try:
            same_os = isinstance(minimum, str) and rollout.parse_build(minimum, "app minimum macOS") == rollout.parse_build(head["minimumSystemVersion"], "manifest minimum macOS")
        except rollout.RolloutError:
            same_os = False
        exclude_unless(same_os, "app minimum macOS differs from the rollout manifest")
        bundle = artifact.get("bundle", {}) if isinstance(artifact.get("bundle"), dict) else {}
        exclude_unless(info.get("RepoPromptSigningMode") == bundle.get("signing_mode"), "app signing mode differs from the artifact manifest")
        executable = info.get("CFBundleExecutable")
        exclude_unless(isinstance(executable, str) and SAFE_COMPONENT.fullmatch(executable) is not None, "app executable name is unsafe")
        main_relative = f"Contents/MacOS/{executable}"
        executables = artifact.get("executables")
        exclude_unless(isinstance(executables, list) and executables, "artifact manifest lacks an executable inventory")
        listed = set()
        for item in executables:
            exclude_unless(isinstance(item, dict), "artifact executable entry malformed")
            path = _relative_bundle_path(app, item.get("path"))
            listed.add(item["path"])
            expected_digest = item.get("sha256")
            exclude_unless(isinstance(expected_digest, str) and history.DIGEST.fullmatch(expected_digest) is not None and sha256_stream(path) == expected_digest, f"extracted executable {item['path']} differs from the artifact manifest digest")
            lipo = self.run(["/usr/bin/lipo", "-archs", str(path)], TOOL_TIMEOUT)
            exclude_unless(lipo.returncode == 0 and set((lipo.stdout or "").split()) == UNIVERSAL, f"executable {item['path']} is not universal arm64+x86_64")
        exclude_unless(main_relative in listed, "artifact manifest omits the main executable")
        requirement = self.apple["identities"][manifest["signingIdentity"]]["developerIDRequirement"]
        signature = self.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--all-architectures", "--verbose=2", "-R=" + requirement, str(app)], TOOL_TIMEOUT)
        exclude_unless(signature.returncode == 0, "strict all-architecture nested code signature or committed Developer ID requirement failed")
        self.assess(app, "execute")
        return ["bundle-info", "executable-digests", "universal-architectures", "codesign-strict-deep-all-architectures-requirement", "gatekeeper-notarized-execute"]

    def audit_application(self, archive: Path, manifest: dict, head: dict, artifact: dict) -> tuple:
        expanded = zip_preflight(archive, self.app_name)
        work = self.owned_work()
        try:
            if shutil.disk_usage(work).free < 2 * expanded + EXTRACTION_HEADROOM:
                raise AuditEnvironmentError("insufficient free space for bounded extraction")
            extract = work / "extract"
            extract.mkdir()
            result = self.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extract)], TOOL_TIMEOUT)
            exclude_unless(result.returncode == 0, "ZIP extraction failed")
            exclude_unless(sorted(os.listdir(extract)) == [self.app_name], "extracted archive root is not exactly the app bundle")
            app = extract / self.app_name
            exclude_unless(app.is_dir() and not app.is_symlink(), "extracted app root is not a real directory")
            exclude_unless(measure_tree(app) == expanded, "extracted app byte count differs from the ZIP")
            checks = ["zip-layout", "expanded-size"] + self.audit_bundle(app, manifest, head, artifact)
        finally:
            _rmtree(work)
        return expanded, checks

    def audit_package(self, package: Path, manifest: dict, head: dict, artifact: dict) -> list:
        identity = self.apple["identities"][manifest["signingIdentity"]]
        installer = identity.get("developerIDInstallerIdentityName")
        exclude_unless(isinstance(installer, str) and installer, "committed policy lacks an installer identity for this role")
        check = self.run(["/usr/sbin/pkgutil", "--check-signature", str(package)], TOOL_TIMEOUT)
        details = (check.stdout or "") + (check.stderr or "")
        exclude_unless(check.returncode == 0 and installer in details and f"({identity['teamIdentifier']})" in details, "package installer signature differs from the committed identity")
        staple = self.run(["/usr/bin/xcrun", "stapler", "validate", str(package)], TOOL_TIMEOUT)
        exclude_unless(staple.returncode == 0, "package notarization ticket is not stapled")
        self.assess(package, "install")
        # The cpio/pbzx payload is NOT expanded: it cannot be preflighted with
        # the ZIP-equivalent bounds, and package seeds are never downloadable.
        return ["package-installer-signature", "package-stapled", "gatekeeper-notarized-install"]


def parse_sums(path: Path) -> dict:
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = SUMS_LINE.fullmatch(line)
        exclude_unless(match is not None, "malformed SHA256SUMS line")
        exclude_unless(match.group(2) not in result, "duplicate SHA256SUMS entry")
        result[match.group(2)] = match.group(1)
    return result


# --------------------------------------------------------------------------
# Policy, source audit and per-release audit
# --------------------------------------------------------------------------

def load_seed_policy(path: Path) -> dict:
    """Read admission floors; retention/review fields are never read as proof."""
    policy = history.read_json(path)
    history.require(policy.get("schemaVersion") == 1, "unsupported history policy")
    floor, commit = policy.get("historyAdmissionFloorBuild"), policy.get("historyAdmissionFloorCommit")
    history.require(isinstance(floor, str) and isinstance(commit, str) and history.COMMIT.fullmatch(commit) is not None, "seed audit requires a reviewed admission floor build/commit in policy")
    rollout.parse_build(floor, "history admission floor")
    ui_floor = policy.get("historyUIFloorBuild")
    history.require(ui_floor is None or isinstance(ui_floor, str), "invalid history UI floor")
    if ui_floor is not None:
        rollout.parse_build(ui_floor, "history UI floor")
    activation = policy.get("historyEnabledSinceTag")
    history.require(activation is None or isinstance(activation, str) and history.TAG.fullmatch(activation) is not None, "invalid history activation tag")
    return policy


def load_source_audit(path: Path) -> tuple:
    raw = path.read_bytes()
    data = history.parse_json(raw)
    history.require(set(data) <= {"schemaVersion", "intervals", "provenance"} and data.get("schemaVersion") == 1 and isinstance(data.get("intervals"), list), "unsupported source audit format")
    history.require(data.get("provenance") is None or isinstance(data["provenance"], str), "source audit provenance must be text")
    intervals = {}
    for item in data["intervals"]:
        history.require(isinstance(item, dict) and set(item) == {"tag", "fromCommit", "releaseCommit", "verdict", "reasons"}, "malformed source audit interval")
        history.require(isinstance(item["tag"], str) and history.TAG.fullmatch(item["tag"]) is not None and item["tag"] not in intervals, "invalid or duplicate source audit tag")
        history.require(item["fromCommit"] is None or isinstance(item["fromCommit"], str) and history.COMMIT.fullmatch(item["fromCommit"]) is not None, "invalid source audit fromCommit")
        history.require(isinstance(item["releaseCommit"], str) and history.COMMIT.fullmatch(item["releaseCommit"]) is not None, "invalid source audit releaseCommit")
        history.require(item["verdict"] is None or item["verdict"] in PERSISTENCE_VERDICTS, "invalid source audit verdict")
        reasons = item["reasons"]
        history.require(isinstance(reasons, list) and len(reasons) <= 3 and all(isinstance(r, str) and r and history.clean(r) == r and history.truncate_many([r], 200)[0] == r for r in reasons), "invalid source audit reasons")
        history.require((item["verdict"] == "downgrade-break") == bool(reasons) or item["verdict"] is None, "downgrade-break verdicts require reasons; other verdicts must not carry reasons")
        intervals[item["tag"]] = item
    return intervals, hashlib.sha256(raw).hexdigest()


def _reason(error: BaseException, context: AuditContext) -> str:
    text = str(error)
    for root, label in ((str(context.snapshot.root), "<snapshot>"), (str(context.work_dir), "<work>"), (str(context.source), "<source>")):
        text = text.replace(root, label)
    return history.truncate_many([history.clean(text) or type(error).__name__], 200)[0]


def validate_rollout(context: AuditContext, release: Release) -> None:
    manifest_path = context.snapshot.asset(release, ROLLOUT_NAME, SMALL_ASSET_LIMIT)
    appcast_path = context.snapshot.asset(release, APPCAST_NAME, SMALL_ASSET_LIMIT)
    exclude_unless(appcast_path == manifest_path.with_name(APPCAST_NAME), "appcast is not beside its rollout manifest")
    manifest = rollout.validate_tip_manifest_pair(context.apple, manifest_path, appcast_path, f"seed {release.tag}")
    commit = manifest["releaseCommit"]
    exclude_unless(manifest["sourceTag"] == release.tag == "tip-" + commit[:12], "release tag differs from its rollout manifest commit")
    release.manifest = manifest
    release.manifest_path = manifest_path
    release.build = rollout.parse_build(manifest["buildNumber"], "seed build")


def audit_release(context: AuditContext, release: Release) -> dict:
    """Full independent audit. Raises SeedExclusion (or History/Rollout errors)."""
    manifest = release.manifest
    head = manifest["appcastItems"][0]
    role, commit, build = manifest["currentRole"], manifest["releaseCommit"], manifest["buildNumber"]
    source = context.source
    exclude_unless(subprocess.run(["git", "-C", str(source), "cat-file", "-e", f"{commit}^{{commit}}"], capture_output=True).returncode == 0, "seed release commit is absent from the approved source")
    admission.admit_source(context.policy, source, commit, build)
    exclude_unless(history.is_ancestor(source, commit, context.candidate_commit), "seed release is not an ancestor of the approved candidate")

    exclude_unless(release.asset_problem is None, release.asset_problem or "")
    enclosure_name = head["enclosureName"]
    suffix = rollout.ROLE_ENCLOSURE_SUFFIX[role]
    stem = enclosure_name[: -len(suffix)]
    artifact_name = manifest["appArtifactManifest"]["name"]
    metadata_name = f"{stem}-metadata.json"
    expected = {ROLLOUT_NAME, APPCAST_NAME, SUMS_NAME, artifact_name, metadata_name, enclosure_name}
    if head["installationType"] == "application":
        expected.add(f"{stem}.dmg")
    actual = set(release.assets)
    exclude_unless(actual == expected, f"asset inventory mismatch: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")

    snapshot = context.snapshot
    artifact_path = snapshot.asset(release, artifact_name, SMALL_ASSET_LIMIT)
    metadata_path = snapshot.asset(release, metadata_name, SMALL_ASSET_LIMIT)
    sums = parse_sums(snapshot.asset(release, SUMS_NAME, SMALL_ASSET_LIMIT))
    exclude_unless(set(sums) == expected - {SUMS_NAME}, "SHA256SUMS entry set differs from the release inventory")
    digests = {}
    for name, path in ((ROLLOUT_NAME, release.manifest_path), (APPCAST_NAME, release.manifest_path.with_name(APPCAST_NAME)), (artifact_name, artifact_path), (metadata_name, metadata_path)):
        digests[name] = sha256_stream(path)
        exclude_unless(digests[name] == sums[name], f"{name} differs from SHA256SUMS")
    exclude_unless(sums[enclosure_name] == head["enclosureSha256"], "SHA256SUMS enclosure digest differs from the rollout manifest")

    metadata = history.read_json(metadata_path)
    expected_metadata = {
        "commit": commit, "short_sha": commit[:12], "tag": release.tag,
        "marketing_version": manifest["marketingVersion"], "build_number": build,
        "rollout_role": role, "signing_identity": manifest["signingIdentity"],
        "migration_phase": manifest["migrationPhase"],
    }
    exclude_unless(metadata == expected_metadata, "release metadata differs from the rollout manifest")
    artifact = history.read_json(artifact_path)

    exclude_unless(release.assets[enclosure_name].get("size") == head["enclosureSize"], "release record enclosure size differs from the rollout manifest")
    enclosure = snapshot.asset(release, enclosure_name, ENCLOSURE_LIMIT)
    exclude_unless(os.lstat(enclosure).st_size == head["enclosureSize"], "enclosure size differs from the rollout manifest")
    digests[enclosure_name] = sha256_stream(enclosure)
    exclude_unless(digests[enclosure_name] == head["enclosureSha256"], "enclosure SHA-256 differs from the rollout manifest")
    exclude_unless(context.verify(context.apple["sparkle"]["sparklePublicEdDSAValue"], head["edSignature"], enclosure), "Sparkle EdDSA signature does not verify with the pinned public key")
    checks = ["release-record", "inventory", "sha256sums", "rollout-manifest", "appcast", "artifact-manifest-binding", "metadata", "source-floor", "source-ancestry", "enclosure-size", "enclosure-sha256", "sparkle-eddsa"]

    expanded = None
    if head["installationType"] == "application":
        expanded, archive_checks = context.audit_application(enclosure, manifest, head, artifact)
    else:
        archive_checks = context.audit_package(enclosure, manifest, head, artifact)
    checks += archive_checks
    # Binding/identity/architecture checks from the shared admission module.
    provisional = history.collect_notes(source, None, commit)
    admission.entry_from_manifest(apple_policy=context.apple, policy=context.policy, source=source, manifest_path=release.manifest_path, artifact_path=artifact_path, notes=provisional, expanded_size=expanded, origin="seed")
    return {
        "artifactPath": artifact_path,
        "expandedSize": expanded,
        "record": {
            "tag": release.tag, "buildNumber": build, "releaseCommit": commit, "role": role,
            "assetSha256": dict(sorted(digests.items())),
            "unauditedAssets": sorted(actual - set(digests) - {SUMS_NAME}),
            "checks": checks,
        },
    }


def persistence_hints(source: Path, previous: Optional[str], commit: str) -> Optional[list]:
    if previous is None or not history.is_ancestor(source, previous, commit):
        return None
    output = history.git(source, "diff", "--name-only", "-z", previous, commit, "--", *PERSISTENCE_HINT_PATHS)
    return sorted(name for name in output.split("\0") if name)


def apply_persistence_review(entry: dict, review: Optional[dict], previous: Optional[str]) -> str:
    bound = review is not None and review["releaseCommit"] == entry["releaseCommit"] and review["fromCommit"] == previous and review["verdict"] is not None
    if bound and review["verdict"] == "no-known-downgrade-break":
        return "reviewed-no-known-break"
    reasons = list(review["reasons"]) if bound else [PERSISTENCE_PENDING]
    merged = []
    for reason in reasons + entry["downgradeBarrierReasons"]:
        if reason not in merged:
            merged.append(reason)
    entry["downgradeBarrier"] = True
    entry["downgradeBarrierReasons"] = merged[:3]
    return "reviewed-break" if bound else "pending"


# --------------------------------------------------------------------------
# Bootstrap assembly
# --------------------------------------------------------------------------

@dataclass
class SeedResult:
    evidence: dict
    report: dict
    exit_code: int
    evidence_bytes: bytes = field(default=b"")


def seed_bootstrap(context: AuditContext, source_audit: Optional[dict], source_audit_sha256: Optional[str], expect_live_parent: Optional[str]) -> SeedResult:
    candidate_build = rollout.parse_build(context.candidate_build, "candidate build")
    floor_build = rollout.parse_build(context.policy["historyAdmissionFloorBuild"], "history floor")
    blocking = []
    excluded = []
    observations = {"records": 0, "drafts": 0, "draftsWithHistory": 0, "unpublished": 0, "immutableTrue": 0, "immutableFalse": 0, "immutableUnknown": 0}
    releases = []
    history_seen = False
    by_tag = {}
    for raw in context.snapshot.records():
        observations["records"] += 1
        try:
            release = _release_from_record(raw)
        except history.HistoryError as error:
            excluded.append({"tag": None, "buildNumber": None, "reason": _reason(error, context)})
            continue
        key = {True: "immutableTrue", False: "immutableFalse"}.get(release.immutable, "immutableUnknown")
        observations[key] += 1
        if release.draft:
            observations["drafts"] += 1
            observations["draftsWithHistory"] += HISTORY_ASSET in release.assets
            continue
        if not release.published:
            observations["unpublished"] += 1
            continue
        if HISTORY_ASSET in release.assets:
            history_seen = True
        by_tag.setdefault(release.tag, []).append(release)
    if history_seen:
        blocking.append("A release already carries tip-history.json; history was enabled, so bootstrap is forbidden (recover the signed parent instead).")

    for tag in sorted(by_tag):
        group = by_tag[tag]
        if len(group) > 1:
            excluded.append({"tag": tag, "buildNumber": None, "reason": "duplicate release tag in snapshot"})
            continue
        release = group[0]
        if history.TAG.fullmatch(tag) is None:
            excluded.append({"tag": tag, "buildNumber": None, "reason": "release tag is not a Tip tag"})
            continue
        if tag == context.candidate_tag:
            blocking.append(f"Candidate {tag} is already published; seed bootstrap must precede publication.")
            continue
        try:
            validate_rollout(context, release)
        except RELEASE_DATA_ERRORS as error:
            excluded.append({"tag": tag, "buildNumber": None, "reason": "unorderable: " + _reason(error, context)})
            continue
        releases.append(release)

    builds = {}
    for release in releases:
        builds.setdefault(release.build, []).append(release)
    ordered = []
    for build, group in builds.items():
        if len(group) > 1:
            for release in group:
                excluded.append({"tag": release.tag, "buildNumber": release.manifest["buildNumber"], "reason": "duplicate validated build number"})
        elif build >= candidate_build:
            blocking.append(f"Published release {group[0].tag} has build {group[0].manifest['buildNumber']} >= candidate {context.candidate_build}.")
        else:
            ordered.append(group[0])
    ordered.sort(key=lambda release: release.build, reverse=True)

    admitted = []
    not_evaluated = 0
    for index, release in enumerate(ordered):
        if len(admitted) == REQUIRED_SEEDS:
            not_evaluated += 1
            continue
        if release.build < floor_build:
            excluded.append({"tag": release.tag, "buildNumber": release.manifest["buildNumber"], "reason": "predates the audited history admission floor"})
            continue
        try:
            audit = audit_release(context, release)
        except RELEASE_DATA_ERRORS as error:
            excluded.append({"tag": release.tag, "buildNumber": release.manifest["buildNumber"], "reason": _reason(error, context)})
            continue
        admitted.append((index, release, audit))

    live_parent = ordered[0].tag if ordered else None
    if expect_live_parent is not None and expect_live_parent != live_parent:
        blocking.append(f"Snapshot newest predecessor {live_parent} differs from the pinned live parent {expect_live_parent}.")
    if admitted and admitted[0][1].tag != live_parent:
        blocking.append(f"Newest published predecessor {live_parent} was not admitted; bootstrap liveParent must equal the newest seed.")
    activation = context.policy.get("historyEnabledSinceTag")
    if activation is not None and activation != context.candidate_tag:
        blocking.append(f"Policy historyEnabledSinceTag {activation} differs from candidate {context.candidate_tag}.")

    entries, audits, template, hints = [], [], [], []
    for position, (index, release, audit) in enumerate(admitted):
        commit = release.manifest["releaseCommit"]
        if position + 1 < len(admitted):
            previous = admitted[position + 1][1].manifest["releaseCommit"]
        else:
            previous = None
            if index + 1 < len(ordered):
                older = ordered[index + 1].manifest["releaseCommit"]
                present = subprocess.run(["git", "-C", str(context.source), "cat-file", "-e", f"{older}^{{commit}}"], capture_output=True).returncode == 0
                if present and history.is_ancestor(context.source, older, commit):
                    previous = older
        notes = history.collect_notes(context.source, previous, commit)
        entry = admission.entry_from_manifest(apple_policy=context.apple, policy=context.policy, source=context.source, manifest_path=release.manifest_path, artifact_path=audit["artifactPath"], notes=notes, expanded_size=audit["expandedSize"], origin="seed")
        review = (source_audit or {}).get(release.tag)
        status = apply_persistence_review(entry, review, previous)
        admission.validate_entry(entry, apple_policy=context.apple, policy=context.policy, source=context.source)
        entries.append(entry)
        record = dict(audit["record"])
        record["persistenceAudit"] = status
        audits.append(record)
        template.append({"tag": release.tag, "fromCommit": previous, "releaseCommit": commit, "verdict": review["verdict"] if status != "pending" else None, "reasons": list(review["reasons"]) if status == "reviewed-break" else []})
        paths = persistence_hints(context.source, previous, commit)
        hints.append({"tag": release.tag, "intervalContinuous": paths is not None, "sensitivePathCount": None if paths is None else len(paths), "sensitivePaths": None if paths is None else paths[:HINT_LIMIT]})

    shortfall = REQUIRED_SEEDS - len(entries)
    if shortfall:
        blocking.append(f"Only {len(entries)} of {REQUIRED_SEEDS} predecessors were admitted; shortfall {shortfall}.")
    pending = sum(1 for record in audits if record["persistenceAudit"] == "pending")
    review_gates = list(EXTERNAL_REVIEW_GATES)
    if activation is None:
        review_gates.insert(0, "Policy historyEnabledSinceTag is not yet pinned.")
    if pending:
        review_gates.insert(0, f"{pending} admitted seed(s) carry the blocking persistence-audit-pending barrier.")
    excluded.sort(key=lambda item: (item["buildNumber"] is None, tuple(-n for n in rollout.parse_build(item["buildNumber"], "excluded")) if item["buildNumber"] else (), item["tag"] or "", item["reason"]))
    status = "complete" if not blocking else ("shortfall" if shortfall else "blocked")
    evidence = {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION,
        "historyNeverEnabled": not history_seen,
        "liveParent": live_parent,
        "entries": entries,
        "status": status,
        "candidate": {"tag": context.candidate_tag, "releaseCommit": context.candidate_commit, "buildNumber": context.candidate_build},
        "requiredSeedCount": REQUIRED_SEEDS,
        "admittedSeedCount": len(entries),
        "shortfall": shortfall,
        "admissionPolicy": {
            "historyAdmissionFloorBuild": context.policy["historyAdmissionFloorBuild"],
            "historyAdmissionFloorCommit": context.policy["historyAdmissionFloorCommit"],
            "historyUIFloorBuild": context.policy.get("historyUIFloorBuild"),
        },
        "inputs": {
            "applePolicySha256": hashlib.sha256(history.canonical(context.apple)).hexdigest(),
            "releaseSnapshotSha256": context.snapshot.releases_sha256,
            "sourceAuditSha256": source_audit_sha256,
        },
        "seedAudits": audits,
        "excluded": excluded,
        "notEvaluatedCount": not_evaluated,
        "blockingGates": blocking,
    }
    evidence_bytes = history.canonical(evidence)
    report = {
        "status": status,
        "evidenceSha256": hashlib.sha256(evidence_bytes).hexdigest(),
        "admittedSeedCount": len(entries),
        "shortfall": shortfall,
        "blockingGates": blocking,
        "externalReviewGates": review_gates,
        "excluded": excluded,
        "notEvaluatedCount": not_evaluated,
        "releaseObservations": observations,
        "persistenceReviewTemplate": {"schemaVersion": 1, "intervals": template},
        "persistenceReviewHints": hints,
    }
    return SeedResult(evidence=evidence, report=report, exit_code=0 if not blocking else 2, evidence_bytes=evidence_bytes)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

@dataclass
class Tools:
    run: Runner
    verify: Verifier
    fetch: Optional[Fetcher]

    @classmethod
    def default(cls, fetch: bool) -> "Tools":
        return cls(run=run_tool, verify=trusted_sparkle_verifier(run_tool), fetch=BoundedFetcher() if fetch else None)


def _write_atomic(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        with open(temporary, "xb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            temporary.unlink()


def load_committed_apple_policy(path: Path) -> dict:
    """Enforce, not merely record, the committed pinned key/identity binding.

    A supplied policy is accepted only when its canonical content equals the
    tool's committed DEFAULT_APPLE_POLICY; there is no key/requirement override.
    """
    committed = rollout.load_policy(DEFAULT_APPLE_POLICY)
    supplied = rollout.load_policy(path)
    history.require(history.canonical(supplied) == history.canonical(committed), "--apple-policy must match the committed Scripts/apple_identity_policy.json (pinned Sparkle key and Developer ID requirements)")
    rollout.validate_identity_transition_package(supplied)
    return supplied


def build_context(args: argparse.Namespace, tools: Tools) -> AuditContext:
    source = args.approved_source.resolve()
    history.require(history.COMMIT.fullmatch(args.candidate_commit) is not None and args.candidate_tag == "tip-" + args.candidate_commit[:12], "candidate tag must be tip-<first 12 hex of candidate commit>")
    rollout.parse_build(args.candidate_build, "candidate build")
    history.require(history.git(source, "rev-parse", "HEAD").strip() == args.candidate_commit, "approved source HEAD must equal the candidate commit")
    history.require(history.git(source, "rev-parse", "--is-shallow-repository").strip() == "false", "full approved source history required")
    apple = load_committed_apple_policy(args.apple_policy)
    policy = load_seed_policy(args.policy)
    snapshot = Snapshot(args.release_snapshot.resolve(), rollout.update_repository(apple, "tip"), tools.fetch)
    work_dir = (args.work_dir or Path(tempfile.gettempdir())).resolve()
    return AuditContext(source=source, policy=policy, apple=apple, snapshot=snapshot, candidate_tag=args.candidate_tag, candidate_commit=args.candidate_commit, candidate_build=args.candidate_build, work_dir=work_dir, run=tools.run, verify=tools.verify)


def run_cli(args: argparse.Namespace, tools: Tools) -> SeedResult:
    context = build_context(args, tools)
    source_audit, source_audit_sha = (None, None)
    if args.source_audit is not None:
        source_audit, source_audit_sha = load_source_audit(args.source_audit)
    if args.expect_live_parent is not None:
        history.require(history.TAG.fullmatch(args.expect_live_parent) is not None, "invalid --expect-live-parent tag")
    result = seed_bootstrap(context, source_audit, source_audit_sha, args.expect_live_parent)
    _write_atomic(args.output, result.evidence_bytes)
    if args.report is not None:
        _write_atomic(args.report, history.canonical(result.report))
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    seed = sub.add_parser("seed-bootstrap", help="Audit up to 29 published predecessors into bootstrap evidence")
    seed.add_argument("--approved-source", type=Path, required=True, help="Full-history checkout whose HEAD is the candidate commit")
    seed.add_argument("--policy", type=Path, required=True, help="Tip history policy (admission floors)")
    seed.add_argument("--apple-policy", type=Path, default=DEFAULT_APPLE_POLICY, help="Committed Apple identity policy (pinned key, identities, requirements)")
    seed.add_argument("--release-snapshot", type=Path, required=True, help="Directory with releases.json and assets/<tag>/<name>")
    seed.add_argument("--candidate-tag", required=True)
    seed.add_argument("--candidate-commit", required=True)
    seed.add_argument("--candidate-build", required=True)
    seed.add_argument("--expect-live-parent", help="Live parent tag pinned by resolve-parent; must equal the newest predecessor")
    seed.add_argument("--source-audit", type=Path, help="Externally reviewed per-interval persistence verdicts")
    seed.add_argument("--fetch", action="store_true", help="Fetch missing assets from exact official URLs into the snapshot cache")
    seed.add_argument("--work-dir", type=Path, help="Parent directory for owned temporary extraction (always removed)")
    seed.add_argument("--output", type=Path, required=True, help="Bootstrap evidence JSON (canonical bytes)")
    seed.add_argument("--report", type=Path, help="Review report with gates, exclusions and persistence review template")
    return parser


def main(argv: Optional[list] = None, tools: Optional[Tools] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = run_cli(args, tools or Tools.default(args.fetch))
    except (history.HistoryError, rollout.RolloutError, AuditEnvironmentError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"tip-history-seed: {error}", file=sys.stderr)
        return 1
    print(f"tip-history-seed: status={result.evidence['status']} admitted={result.evidence['admittedSeedCount']}/{REQUIRED_SEEDS} evidenceSha256={result.report['evidenceSha256']}")
    for gate in result.evidence["blockingGates"]:
        print(f"BLOCKING: {gate}")
    for gate in result.report["externalReviewGates"]:
        print(f"REVIEW: {gate}")
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
