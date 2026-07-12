#!/usr/bin/env python3
"""SwiftPM build cache inventory identity and read-only diagnostics for RepoPrompt CE."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import enum
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

BUILD_CACHE_DIAGNOSTIC_MAX_ROWS = 12


class CacheSource(enum.Enum):
    """How the effective scratch path was chosen."""

    EXACT_ENV = "exact-env"
    DEVELOPER_ROOT = "developer-root"
    DEFAULT = "default"


def repo_hash(repo_root: Path) -> str:
    """Stable hash identifying the resolved repository root."""
    return hashlib.sha256(str(repo_root.resolve()).encode("utf-8")).hexdigest()


def format_bytes(byte_count: Optional[int]) -> str:
    if byte_count is None:
        return "n/a"
    value = float(max(0, int(byte_count)))
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} B"
    return f"{value:.1f} {unit}"


def directory_size_bytes(path: Path) -> Optional[int]:
    try:
        if not path.exists():
            return None
        if path.is_symlink():
            path = path.resolve(strict=True)
    except OSError:
        return None

    try:
        result = subprocess.run(
            ["du", "-sk", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode == 0:
            first = result.stdout.strip().split()[0]
            return int(first) * 1024
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass

    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        stat_result = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(Path(entry.path))
                    else:
                        total += stat_result.st_size
        except NotADirectoryError:
            try:
                total += current.stat(follow_symlinks=False).st_size
            except OSError:
                pass
        except OSError:
            continue
    return total


def latest_mtime(path: Path) -> Optional[float]:
    try:
        return path.stat(follow_symlinks=False).st_mtime
    except OSError:
        return None


def managed_worktree_container(repo_root: Path) -> Optional[Path]:
    """Return the .repoprompt-worktrees container that owns repo_root, if any."""
    try:
        resolved_root = repo_root.resolve()
    except OSError:
        resolved_root = repo_root
    try:
        parent = resolved_root.parent
        if parent.parent.name == ".repoprompt-worktrees":
            return parent
    except (IndexError, OSError):
        return None
    return None


def managed_worktree_repo_roots(repo_root: Path) -> List[Path]:
    """All real repo roots under the same managed worktree container, including current.

    Symlinked children are resolved and only included if they point inside the
    container, so stale or outside links do not get treated as managed worktrees.
    """
    try:
        resolved_root = repo_root.resolve()
    except OSError:
        resolved_root = repo_root
    container = managed_worktree_container(resolved_root)
    if container is None or not container.exists():
        return [resolved_root]
    try:
        resolved_container = container.resolve()
    except OSError:
        resolved_container = container

    roots: List[Path] = []
    for child in sorted(resolved_container.iterdir()):
        if not child.is_dir():
            continue
        try:
            resolved_child = child.resolve(strict=True)
        except OSError:
            continue
        if not resolved_child.is_dir():
            continue
        if not is_path_within(resolved_child, resolved_container):
            continue
        if (resolved_child / ".build").exists() or (resolved_child / "Package.swift").exists():
            roots.append(resolved_child)
    if resolved_root not in roots:
        roots.append(resolved_root)
    return roots


def _toolchain_id(env: Dict[str, str]) -> str:
    inputs = "|".join(
        env.get(k, "") for k in ("DEVELOPER_DIR", "TOOLCHAINS", "SWIFT_EXEC")
    )
    if not inputs.strip("|"):
        return "default"
    return hashlib.sha256(inputs.encode("utf-8")).hexdigest()[:8]


def _macos_version() -> Optional[str]:
    try:
        result = subprocess.run(
            ["sw_vers", "-productVersion"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        version = result.stdout.strip()
        if version:
            return ".".join(version.split(".")[:2])
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        version = platform.mac_ver()[0]
        if version:
            return ".".join(version.split(".")[:2])
    except Exception:
        pass
    return None


def _destination_id(env: Optional[Dict[str, str]] = None) -> str:
    if env is None:
        env = dict(os.environ)
    target_triple = env.get("SWIFT_TARGET_TRIPLE")
    if target_triple:
        return target_triple
    machine = platform.machine().lower() or "unknown"
    system = platform.system()
    if system == "Darwin":
        version = _macos_version()
        if version:
            return f"{machine}-apple-macosx{version}"
        return f"{machine}-apple-macosx"
    if system == "Linux":
        return f"{machine}-unknown-linux-gnu"
    return f"{machine}-unknown-{system.lower()}"


def _safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._") or "repo"


@dataclasses.dataclass(frozen=True)
class SwiftPMCacheIdentity:
    """The canonical identity of a SwiftPM build cache for a repo/worktree + config."""

    repo_root: Path
    repo_hash: str
    worktree_name: str
    toolchain_id: str
    destination_id: str
    configuration: str
    source: CacheSource
    effective_path: Path
    exact_path: Optional[str] = None
    developer_root: Optional[str] = None

    def key(self) -> str:
        parts = [
            self.repo_hash[:8],
            self.worktree_name,
            self.destination_short(),
            self.configuration,
        ]
        if self.toolchain_id != "default":
            parts.append(self.toolchain_id)
        return "-".join(parts)

    def destination_short(self) -> str:
        return self.destination_id.replace("-", "_")

    def is_default(self) -> bool:
        return self.source == CacheSource.DEFAULT

    def describe(self) -> str:
        parts = [f"source={self.source.value}", f"key={self.key()}"]
        if self.exact_path:
            parts.append(f"exact_path={self.exact_path}")
        if self.developer_root:
            parts.append(f"developer_root={self.developer_root}")
        return " ".join(parts)


def resolve_swiftpm_cache_identity(
    repo_root: Path, configuration: str, env: Optional[Dict[str, str]] = None
) -> SwiftPMCacheIdentity:
    """Determine the authoritative SwiftPM scratch path and identity for a repo root.

    Resolution order:
      1. REPOPROMPT_SWIFTPM_SCRATCH_PATH (exact path, highest priority)
      2. REPOPROMPT_DEVELOPER_SWIFTPM_SCRATCH_ROOT (deterministic keyed subdirectory)
      3. <repoRoot>/.build (default)
    """
    if env is None:
        env = dict(os.environ)
    configuration = str(configuration).lower()
    resolved_root = repo_root.resolve()
    worktree_name = _safe_name(resolved_root.name)
    rhash = repo_hash(resolved_root)
    toolchain = _toolchain_id(env)
    destination = _destination_id(env)

    exact_path = env.get("REPOPROMPT_SWIFTPM_SCRATCH_PATH")
    if exact_path:
        try:
            effective_path = Path(exact_path).expanduser().resolve(strict=False)
        except (OSError, RuntimeError):
            effective_path = Path(exact_path).expanduser().absolute()
        return SwiftPMCacheIdentity(
            repo_root=resolved_root,
            repo_hash=rhash,
            worktree_name=worktree_name,
            toolchain_id=toolchain,
            destination_id=destination,
            configuration=configuration,
            source=CacheSource.EXACT_ENV,
            effective_path=effective_path,
            exact_path=str(Path(exact_path).expanduser()),
        )

    developer_root = env.get("REPOPROMPT_DEVELOPER_SWIFTPM_SCRATCH_ROOT")
    if developer_root:
        try:
            base = Path(developer_root).expanduser().resolve()
        except (OSError, RuntimeError):
            base = Path(developer_root).expanduser().absolute()
        identity = SwiftPMCacheIdentity(
            repo_root=resolved_root,
            repo_hash=rhash,
            worktree_name=worktree_name,
            toolchain_id=toolchain,
            destination_id=destination,
            configuration=configuration,
            source=CacheSource.DEVELOPER_ROOT,
            effective_path=base,
            developer_root=str(base),
        )
        identity = dataclasses.replace(identity, effective_path=base / identity.key())
        return identity

    return SwiftPMCacheIdentity(
        repo_root=resolved_root,
        repo_hash=rhash,
        worktree_name=worktree_name,
        toolchain_id=toolchain,
        destination_id=destination,
        configuration=configuration,
        source=CacheSource.DEFAULT,
        effective_path=resolved_root / ".build",
    )


def is_path_within(path: Path, root: Path) -> bool:
    """Return True if path is the same as or under root, resolving symlinks carefully."""
    try:
        resolved_path = path.resolve()
        resolved_root = root.resolve()
        return resolved_path == resolved_root or resolved_root in resolved_path.parents
    except OSError:
        return False


def is_active_swiftpm_scratch(path: Path) -> bool:
    """True if another process appears to be actively using this scratch directory."""
    lock_path = path / ".lock"
    if not lock_path.exists():
        return False
    try:
        with lock_path.open("r+") as lock_file:
            fd = lock_file.fileno()
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except (OSError, IOError):
        return True


def debug_app_bundle_path() -> Path:
    root = os.environ.get(
        "REPOPROMPT_DEBUG_APP_ROOT",
        str(Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "DebugApps"),
    )
    return Path(os.environ.get("REPOPROMPT_DEBUG_APP_BUNDLE", str(Path(root) / "RepoPrompt.app")))


def _debug_app_provenance_path(bundle: Path) -> Path:
    return bundle / "Contents" / "Resources" / "RepoPromptDebugProvenance.json"


def _read_debug_app_provenance(bundle: Path) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(_debug_app_provenance_path(bundle).read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def is_live_bound_to_path(path: Path, repo_root: Path) -> bool:
    """True if the running debug app provenance points to this repo root/worktree."""
    provenance = _read_debug_app_provenance(debug_app_bundle_path())
    if not provenance:
        return False
    provenance_root = provenance.get("repoRoot") or provenance.get("worktreePath")
    if not provenance_root:
        return False
    try:
        return Path(provenance_root).resolve() == repo_root.resolve()
    except OSError:
        return False


def is_dirty_worktree(worktree_root: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(worktree_root), "status", "--porcelain"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return False


def _list_developer_root_candidates(
    repo_root: Path, developer_root: Optional[str], configuration: str
) -> List[Path]:
    if not developer_root:
        return []
    try:
        base = Path(developer_root).expanduser().resolve()
    except (OSError, RuntimeError):
        return []
    if not base.exists() or not base.is_dir():
        return []
    rhash = repo_hash(repo_root)
    candidates: List[Path] = []
    for child in base.iterdir():
        if not child.is_dir():
            continue
        if child.name.startswith(rhash[:8]):
            candidates.append(child)
    return candidates


def operation_diagnostics_build_cache(repo_root: Path, args: Dict[str, Any]) -> int:
    limit = int(args.get("limit") or BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)
    limit = max(1, min(limit, 100))
    env = args.get("env") or dict(os.environ)
    configuration = str(args.get("configuration") or env.get("REPOPROMPT_PACKAGE_CONFIGURATION") or "debug")
    identity = resolve_swiftpm_cache_identity(repo_root, configuration, env)

    print("Build cache diagnostics", flush=True)
    print(f"Cache identity: {identity.describe()}", flush=True)
    current_build = repo_root / ".build"
    if current_build.exists():
        symlink_note = ""
        if current_build.is_symlink():
            with contextlib.suppress(OSError):
                symlink_note = f" -> {current_build.resolve(strict=True)}"
        print(f"Current .build: {format_bytes(directory_size_bytes(current_build))}{symlink_note}", flush=True)
    else:
        print("Current .build: missing", flush=True)

    effective = identity.effective_path
    if effective != current_build and effective.exists():
        print(
            f"Effective scratch path: {effective} ({format_bytes(directory_size_bytes(effective))})",
            flush=True,
        )

    container = managed_worktree_container(repo_root)
    if container is None or not container.exists():
        print("Managed worktree container: not detected", flush=True)
        return 0

    rows: List[Tuple[int, Optional[float], str, Path]] = []
    for child in sorted(container.iterdir(), key=lambda item: item.name):
        if not child.is_dir():
            continue
        try:
            resolved_child = child.resolve(strict=True)
        except OSError:
            continue
        if not resolved_child.is_dir() or not is_path_within(resolved_child, container):
            continue
        worktree_identity = resolve_swiftpm_cache_identity(resolved_child, configuration, env)
        build_dir = worktree_identity.effective_path
        size = directory_size_bytes(build_dir)
        if size is None:
            continue
        rows.append((size, latest_mtime(build_dir), resolved_child.name, build_dir))

    if identity.developer_root:
        for candidate in _list_developer_root_candidates(
            repo_root, identity.developer_root, configuration
        ):
            if candidate in {r[3] for r in rows}:
                continue
            size = directory_size_bytes(candidate)
            if size is None:
                continue
            rows.append((size, latest_mtime(candidate), candidate.name, candidate))

    total = sum(size for size, _mtime, _name, _path in rows)
    print(f"Managed worktree container: {container}", flush=True)
    print(f"Worktree .build total: {format_bytes(total)} across {len(rows)} build director{'y' if len(rows) == 1 else 'ies'}", flush=True)
    if not rows:
        return 0

    print("Top .build directories:", flush=True)
    for size, mtime, name, path in sorted(rows, key=lambda row: row[0], reverse=True)[:limit]:
        mtime_text = "unknown" if mtime is None else time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        print(f"  {format_bytes(size):>9}  {name}  {path}  modified={mtime_text}", flush=True)
    return 0


@dataclasses.dataclass
class BuildCacheEntry:
    path: Path
    repo_root: Path
    identity: SwiftPMCacheIdentity
    size_bytes: Optional[int]
    mtime: Optional[float]
    current: bool
    skip_reasons: List[str]

    @property
    def eligible(self) -> bool:
        return not self.skip_reasons


@dataclasses.dataclass
class BuildCacheCleanupPlan:
    entries: List[BuildCacheEntry]
    apply: bool
    dry_run: bool
    confirmed: bool

    @property
    def eligible_entries(self) -> List[BuildCacheEntry]:
        return [e for e in self.entries if e.eligible]

    @property
    def total_size_bytes(self) -> int:
        return sum(e.size_bytes or 0 for e in self.eligible_entries)

    def to_text(self) -> str:
        lines: List[str] = []
        lines.append("Build cache cleanup plan")
        lines.append(f"dry_run={self.dry_run} apply={self.apply} confirmed={self.confirmed}")
        if not self.eligible_entries:
            lines.append("No eligible cache directories to remove.")
        else:
            lines.append(f"Eligible directories ({len(self.eligible_entries)} entries, {format_bytes(self.total_size_bytes)}):")
            for e in self.eligible_entries:
                mtime_text = "unknown" if e.mtime is None else time.strftime("%Y-%m-%d %H:%M", time.localtime(e.mtime))
                lines.append(f"  {format_bytes(e.size_bytes):>9}  {e.path}  modified={mtime_text}")
        skipped = [e for e in self.entries if not e.eligible]
        if skipped:
            lines.append(f"Skipped directories ({len(skipped)}):")
            for e in skipped:
                reasons = ", ".join(e.skip_reasons)
                lines.append(f"  {format_bytes(e.size_bytes):>9}  {e.path}  reasons={reasons}")
        return "\n".join(lines)


def plan_build_cache_cleanup(
    repo_root: Path,
    *,
    dry_run: bool = True,
    apply: bool = False,
    confirm: bool = False,
    limit: Optional[int] = None,
    env: Optional[Dict[str, str]] = None,
) -> BuildCacheCleanupPlan:
    """Build a conservative, safety-checked plan for cache cleanup.

    By default the plan is dry-run. Actual deletion requires both apply=True and
    confirm=True, and the caller must ensure the current .build is never removed.
    """
    if env is None:
        env = dict(os.environ)
    resolved_root = repo_root.resolve()
    repo_roots = managed_worktree_repo_roots(resolved_root)
    entries: List[BuildCacheEntry] = []
    seen_paths: set[Path] = set()

    for config in ("debug", "release"):
        identity = resolve_swiftpm_cache_identity(resolved_root, config, env)
        configuration = identity.configuration

        def add_entry(path: Path, worktree_root: Path, current: bool) -> None:
            path = path.expanduser().absolute()
            is_symlink = path.is_symlink()
            if not is_symlink:
                try:
                    path = path.resolve()
                except OSError:
                    pass
            if path in seen_paths:
                return
            seen_paths.add(path)
            if not path.exists() and not is_symlink:
                return

            skip_reasons: List[str] = []
            if current:
                skip_reasons.append("current")
            roots: List[Path] = list(repo_roots)
            if identity.developer_root:
                roots.append(Path(identity.developer_root))
            if not any(is_path_within(path, r) for r in roots):
                skip_reasons.append("out-of-scope")
            if is_symlink:
                skip_reasons.append("symlink")
            if not is_symlink and is_active_swiftpm_scratch(path):
                skip_reasons.append("active-lock")
            if is_live_bound_to_path(path, worktree_root):
                skip_reasons.append("live-bound")
            if is_dirty_worktree(worktree_root):
                skip_reasons.append("dirty-worktree")

            size = 0 if is_symlink else directory_size_bytes(path)
            mtime = path.lstat().st_mtime if is_symlink else latest_mtime(path)
            entry_identity = resolve_swiftpm_cache_identity(worktree_root, configuration, env)
            entries.append(
                BuildCacheEntry(
                    path=path,
                    repo_root=worktree_root,
                    identity=entry_identity,
                    size_bytes=size,
                    mtime=mtime,
                    current=current,
                    skip_reasons=skip_reasons,
                )
            )

        for worktree_root in repo_roots:
            worktree_identity = resolve_swiftpm_cache_identity(worktree_root, configuration, env)
            add_entry(worktree_identity.effective_path, worktree_root, worktree_root == resolved_root)
            legacy_build = worktree_root / ".build"
            if legacy_build != worktree_identity.effective_path and legacy_build.exists():
                add_entry(legacy_build, worktree_root, worktree_root == resolved_root)

        if identity.developer_root:
            for candidate in _list_developer_root_candidates(resolved_root, identity.developer_root, configuration):
                if candidate in seen_paths:
                    continue
                add_entry(candidate, resolved_root, current=False)

    entries.sort(key=lambda e: (not e.skip_reasons, e.current, e.path.name), reverse=True)
    if limit is not None:
        entries = entries[:limit]
    return BuildCacheCleanupPlan(entries=entries, apply=apply, dry_run=dry_run, confirmed=confirm)


def execute_build_cache_cleanup(plan: BuildCacheCleanupPlan) -> int:
    """Execute a prepared cleanup plan. Returns 0 on success, 1 on failure."""
    if not plan.apply:
        print(plan.to_text())
        return 0
    if not plan.confirmed:
        print("ERROR: cache cleanup --apply requires --confirm", file=sys.stderr)
        return 1
    if not plan.eligible_entries:
        print(plan.to_text())
        return 0

    failed = 0
    for entry in plan.eligible_entries:
        try:
            if not entry.path.exists() or entry.path.is_symlink():
                print(f"Skipping {entry.path}: no longer present or is a symlink", flush=True)
                continue
            if is_active_swiftpm_scratch(entry.path):
                print(f"Skipping {entry.path}: active lock acquired since plan", flush=True)
                continue
            if is_live_bound_to_path(entry.path, entry.repo_root):
                print(f"Skipping {entry.path}: became live-bound since plan", flush=True)
                continue
            scope_roots: List[Path] = [entry.repo_root]
            if entry.identity.developer_root:
                scope_roots.append(Path(entry.identity.developer_root).expanduser().resolve())
            if entry.identity.exact_path:
                scope_roots.append(Path(entry.identity.exact_path).expanduser().resolve())
            if not any(is_path_within(entry.path, r) for r in scope_roots):
                print(f"Skipping {entry.path}: out of scope since plan", flush=True)
                continue
            if is_dirty_worktree(entry.repo_root):
                print(f"Skipping {entry.path}: worktree became dirty since plan", flush=True)
                continue
            print(f"Removing {entry.path}", flush=True)
            shutil.rmtree(entry.path)
        except OSError as exc:
            print(f"ERROR: failed to remove {entry.path}: {exc}", file=sys.stderr)
            failed += 1
    if failed:
        return 1
    print(f"Removed {len(plan.eligible_entries)} cache directories ({format_bytes(plan.total_size_bytes)}).")
    return 0


def operation_cache_cleanup(repo_root: Path, args: Dict[str, Any]) -> int:
    env = args.get("env") or dict(os.environ)
    dry_run = not bool(args.get("apply"))
    apply = bool(args.get("apply"))
    confirm = bool(args.get("confirm"))
    limit = args.get("limit")
    if limit is not None:
        limit = max(1, int(limit))
    plan = plan_build_cache_cleanup(
        repo_root,
        dry_run=dry_run,
        apply=apply,
        confirm=confirm,
        limit=limit,
        env=env,
    )
    if not apply:
        print(plan.to_text())
        return 0
    return execute_build_cache_cleanup(plan)


def _command_line_path() -> int:
    parser = argparse.ArgumentParser(prog="cache_inventory.py")
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--configuration", default="debug")
    parser.add_argument("--format", choices=["path", "json", "key", "identity"], default="path")
    parser.add_argument("--cleanup-plan", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--limit", type=int, default=None)
    ns = parser.parse_args()

    if ns.cleanup_plan:
        plan = plan_build_cache_cleanup(
            ns.repo_root,
            dry_run=not ns.apply,
            apply=ns.apply,
            confirm=ns.confirm,
            limit=ns.limit,
        )
        print(plan.to_text())
        return execute_build_cache_cleanup(plan) if ns.apply else 0

    identity = resolve_swiftpm_cache_identity(ns.repo_root, ns.configuration)
    if ns.format == "path":
        print(identity.effective_path)
    elif ns.format == "key":
        print(identity.key())
    elif ns.format == "identity":
        print(identity.describe())
    else:
        print(json.dumps(dataclasses.asdict(identity), default=str, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_command_line_path())
    except KeyboardInterrupt:
        raise SystemExit(130)
