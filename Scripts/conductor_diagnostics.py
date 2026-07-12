#!/usr/bin/env python3
"""Read-only/conductor diagnostics used by run_operation_runner.

These diagnostics are intentionally self-contained so they can be imported by
conductor self-tests without pulling the full daemon module into a circular
import.  They run as the child process of a conductor __operation_runner job.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# Reuse the same regex vocabulary as conductor's OutputSummarizer so focused-build
# warning/error counts are comparable with terminal summary counts.
WARNING_RE = re.compile(r"(: warning:|^warning:|^WARNING:)", re.IGNORECASE)
ERROR_RE = re.compile(r"(: error:|^error:|error: emit-module command failed|Command SwiftCompile failed|Command CompileSwift failed|fatal error:)")

# Progress/task line emitted by swift build / swift test.
SWIFT_PROGRESS_RE = re.compile(r"^\[(\d+)/(\d+)\]\s+(\S.*)$")
# Compiling / Emitting module / Wrapping AST / Write / Linking / etc.
#   [3/7] Compiling swift_probe swift_probe.swift
#   [4/7] Emitting module swift_probe
#   [5/8] Wrapping AST for swift_probe for debugging
#   [7/8] Linking swift_probe
SWIFT_TASK_RE = re.compile(r"^(Compiling|Emitting module|Wrapping AST|Write|Linking)\s+(.*)")

BUILD_COMPLETE_RE = re.compile(r"Build complete!\s*\(([\d.]+)s\)")
TEST_EXECUTED_RE = re.compile(r"Executed\s+(\d+)\s+test.*?in\s+([\d.]+)\s+\(([\d.]+)\)\s+seconds")


def now() -> float:
    return time.time()


def format_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "n/a"
    seconds = max(0.0, float(seconds))
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)}m {seconds:.0f}s"
    hours, minutes = divmod(minutes, 60)
    return f"{int(hours)}h {int(minutes)}m {seconds:.0f}s"


def format_bytes(byte_count: Optional[int]) -> str:
    if byte_count is None:
        return "n/a"
    value = float(max(0, int(byte_count)))
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024:
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} PiB"


def directory_size_bytes(path: Path) -> Optional[int]:
    """Return an approximate size in bytes for ``path``.

    Top-level symlinks are resolved before measuring. ``du -sk`` is preferred;
    if it is unavailable, a manual walk is used. The manual walk does not follow
    directory symlinks inside the tree, so nested symlinked directories may be
    undercounted. This is acceptable for the read-only scratch-size estimate.
    """
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


def process_resource_snapshot() -> Dict[int, Tuple[int, int, str]]:
    """Return a snapshot of all processes: pid -> (ppid, rss_kb, command).

    RSS is in kilobytes (the units used by `ps -o rss` on both Linux and macOS).
    """
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,rss=,command="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2.0,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if result.returncode != 0:
        return {}

    snapshot: Dict[int, Tuple[int, int, str]] = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            rss = int(parts[2])
        except ValueError:
            continue
        if pid > 0:
            snapshot[pid] = (ppid, rss, parts[3])
    return snapshot


def process_tree_resources(root_pid: int, snapshot: Optional[Dict[int, Tuple[int, int, str]]] = None) -> Tuple[int, int, int, List[int]]:
    """Sum RSS for all descendants of root_pid (including root_pid itself).

    Returns (sum_rss_kb, max_single_rss_kb, pid_count, pids).
    """
    if snapshot is None:
        snapshot = process_resource_snapshot()
    if root_pid not in snapshot:
        return (0, 0, 0, [])

    children: Dict[int, List[int]] = defaultdict(list)
    for pid, (ppid, _rss, _cmd) in snapshot.items():
        if pid != ppid:
            children[ppid].append(pid)

    visited: set[int] = set()
    pids: List[int] = []
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in visited:
            continue
        visited.add(pid)
        pids.append(pid)
        stack.extend(children.get(pid, []))

    sum_rss = 0
    max_rss = 0
    for pid in pids:
        rss = snapshot[pid][1]
        sum_rss += rss
        if rss > max_rss:
            max_rss = rss
    return (sum_rss, max_rss, len(pids), pids)


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


@dataclasses.dataclass
class _ResourceSampler:
    """Sample peak process-tree RSS while a child process is running."""

    root_pid: int
    interval: float = 0.1
    _running: bool = False
    _thread: Optional[threading.Thread] = None
    peak_sum_kb: int = 0
    peak_max_kb: int = 0
    peak_pids: int = 0
    sample_count: int = 0

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._sample, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        if self._thread is not None:
            self._thread.join(timeout=self.interval + 0.2)

    def _sample(self) -> None:
        while self._running:
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                total, max_single, pids, _ = process_tree_resources(self.root_pid)
                self.sample_count += 1
                if total > self.peak_sum_kb:
                    self.peak_sum_kb = total
                    self.peak_pids = pids
                if max_single > self.peak_max_kb:
                    self.peak_max_kb = max_single
            time.sleep(self.interval)


@dataclasses.dataclass
class _WarningRecord:
    line: str
    module: Optional[str]
    source: Optional[str]
    message: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "line": self.line.strip(),
            "module": self.module,
            "source": self.source,
            "message": self.message,
        }


class _FocusedBuildParser:
    """Parse `swift build` / `swift test` output into the focused-build report."""

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self.lines: List[str] = []
        self.current_module: Optional[str] = None
        self.build_complete_seconds: Optional[float] = None
        self.build_complete_line: Optional[str] = None
        self.link_count = 0
        self.compile_count = 0
        self.emit_module_count = 0
        self.wrap_ast_count = 0
        self.write_count = 0
        self.progress_max: Optional[int] = None
        self.test_executed: Optional[int] = None
        self.test_seconds: Optional[float] = None
        self.test_wall_seconds: Optional[float] = None
        self.warnings: List[_WarningRecord] = []
        self.errors: List[_WarningRecord] = []

    def _module_from_file(self, file_path: str) -> Optional[str]:
        if not file_path:
            return None
        try:
            rel = (self.repo_root / file_path).relative_to(self.repo_root)
        except ValueError:
            return None
        parts = rel.parts
        if not parts:
            return None
        if parts[0] == "Sources" and len(parts) >= 2:
            directory = parts[1]
            mapping = {
                "RepoPrompt": "RepoPromptApp",
                "RepoPromptExecutable": "RepoPrompt",
                "RepoPromptShared": "RepoPromptShared",
                "RepoPromptMCP": "RepoPromptMCP",
                "RepoPromptC": "RepoPromptC",
                "CSwiftPCRE2": "CSwiftPCRE2",
                "TreeSitterScannerSupport": "TreeSitterScannerSupport",
            }
            return mapping.get(directory, directory)
        return None

    def _extract_file_path(self, line: str) -> Optional[str]:
        # Matches "Sources/Foo.swift:10:5: warning|error: ..." or
        # absolute path variants.
        match = re.match(r"([^:\s]+\.swift):\d+:\d+:\s*(?:warning|error):", line)
        if match:
            return match.group(1)
        return None

    def _extract_message(self, line: str) -> str:
        # Drop the leading file:line:col: prefix if present.
        match = re.match(r"([^:\s]+\.swift:\d+:\d+:\s*(?:warning|error):\s*)?(.+)", line)
        if match:
            return match.group(2).strip()
        return line.strip()

    def _categorize(self, line: str) -> _WarningRecord:
        source = self._extract_file_path(line)
        module = self.current_module or self._module_from_file(source) if source else self.current_module
        message = self._extract_message(line)
        return _WarningRecord(line=line, module=module, source=source, message=message)

    def feed(self, line: str) -> None:
        self.lines.append(line)

        progress = SWIFT_PROGRESS_RE.match(line)
        if progress:
            self.progress_max = max(self.progress_max or 0, int(progress.group(2)))
            task_text = progress.group(3)
            task = SWIFT_TASK_RE.match(task_text)
            if task:
                kind = task.group(1)
                rest = task.group(2).strip()
                if kind == "Compiling":
                    self.compile_count += 1
                    # [3/7] Compiling swift_probe swift_probe.swift
                    # The first token after "Compiling" is the target/module.
                    parts = rest.split(None, 1)
                    self.current_module = parts[0] if parts else None
                elif kind == "Emitting module":
                    self.emit_module_count += 1
                    self.current_module = rest
                elif kind == "Wrapping AST":
                    self.wrap_ast_count += 1
                    # "for swift_probe for debugging" -> extract target
                    m = re.search(r"for\s+(\S+)", rest)
                    self.current_module = m.group(1) if m else None
                elif kind == "Write":
                    self.write_count += 1
                elif kind == "Linking":
                    self.link_count += 1
                    self.current_module = None

        build = BUILD_COMPLETE_RE.search(line)
        if build:
            self.build_complete_seconds = float(build.group(1))
            self.build_complete_line = line.strip()
            self.current_module = None

        test = TEST_EXECUTED_RE.search(line)
        if test:
            self.test_executed = int(test.group(1))
            self.test_seconds = float(test.group(2))
            self.test_wall_seconds = float(test.group(3))

        if WARNING_RE.search(line):
            self.warnings.append(self._categorize(line))
        elif ERROR_RE.search(line):
            self.errors.append(self._categorize(line))

    def _summary_for(self, records: List[_WarningRecord]) -> Dict[str, Any]:
        by_module: Dict[str, int] = Counter()
        by_source: Dict[str, int] = Counter()
        by_message: Dict[str, int] = Counter()
        for record in records:
            if record.module:
                by_module[record.module] += 1
            if record.source:
                by_source[record.source] += 1
            by_message[record.message] += 1
        return {
            "rawCount": len(records),
            "uniqueCount": len(by_message),
            "byModule": dict(by_module),
            "bySource": dict(by_source),
            "uniqueByMessage": dict(by_message),
            "items": [record.to_dict() for record in records[:250]],
        }

    def report(self, swift_invocation: List[str], swift_exit_code: int, scratch_info: Dict[str, Any], peak_rss_bytes: Optional[int]) -> Dict[str, Any]:
        output_bytes = sum(len(line.encode("utf-8", errors="replace")) for line in self.lines)
        return {
            "diagnostic": "focused-build",
            "repoRoot": str(self.repo_root),
            "swift": {
                "command": " ".join(shlex.quote(str(arg)) for arg in swift_invocation),
                "exitCode": swift_exit_code,
            },
            "scratch": scratch_info,
            "output": {
                "lines": len(self.lines),
                "bytes": output_bytes,
            },
            "timing": {
                "build": {
                    "seconds": self.build_complete_seconds,
                    "line": self.build_complete_line,
                },
                "link": {
                    "commandCount": self.link_count,
                },
                "xctest": {
                    "tests": self.test_executed,
                    "seconds": self.test_seconds,
                    "wallSeconds": self.test_wall_seconds,
                } if self.test_executed is not None else None,
            },
            "jobs": {
                "compile": self.compile_count,
                "emitModule": self.emit_module_count,
                "wrapAst": self.wrap_ast_count,
                "link": self.link_count,
                "write": self.write_count,
                "progressMax": self.progress_max,
                "frontend": self.compile_count + self.emit_module_count + self.wrap_ast_count,
            },
            "warnings": self._summary_for(self.warnings),
            "errors": self._summary_for(self.errors),
            "peakChildProcessTreeRSS": {
                "bytes": peak_rss_bytes,
                "human": format_bytes(peak_rss_bytes),
            } if peak_rss_bytes is not None else None,
        }


def _scratch_info(repo_root: Path, build_dir: Path) -> Dict[str, Any]:
    observed_state = "cold" if not build_dir.exists() else "warm"
    size = directory_size_bytes(build_dir) if build_dir.exists() else None
    return {
        "directory": str(build_dir),
        "observedBefore": observed_state,
        "sizeBytes": size,
        "sizeHuman": format_bytes(size),
    }


def run_focused_build(repo_root: Path, args: Dict[str, Any]) -> int:
    """Run a focused, read-only build diagnostic and print a JSON report.

    Args:
        repo_root: path to the Swift package root.
        args: operation args from the daemon; may include ``product``,
            ``testFilter``, and ``runTests``.

    Returns:
        0 if the diagnostic ran (regardless of build/test exit code), or
        1 if the diagnostic itself could not run.
    """
    product = str(args.get("product") or "RepoPrompt")
    test_filter = str(args.get("testFilter") or "")
    run_tests = bool(args.get("runTests") or test_filter)
    build_dir = repo_root / ".build"

    if run_tests:
        invocation = ["swift", "test", "--no-color-diagnostics"]
        if test_filter:
            invocation.extend(["--filter", test_filter])
    else:
        invocation = ["swift", "build", "--product", product, "--no-color-diagnostics"]

    scratch_info = _scratch_info(repo_root, build_dir)

    parser = _FocusedBuildParser(repo_root)
    process: Optional[subprocess.Popen[str]] = None
    sampler: Optional[_ResourceSampler] = None

    start_time = now()
    try:
        process = subprocess.Popen(
            invocation,
            cwd=str(repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            errors="replace",
        )
    except FileNotFoundError:
        print(f"ERROR: {invocation[0]} not found in PATH", flush=True)
        return 1
    except OSError as exc:
        print(f"ERROR: could not launch {invocation[0]}: {exc}", flush=True)
        return 1

    if process.pid:
        sampler = _ResourceSampler(process.pid)
        sampler.start()

    try:
        with process as p:
            assert p.stdout is not None
            for line in p.stdout:
                parser.feed(line)
        exit_code = process.returncode
    except Exception as exc:
        print(f"ERROR: reading swift output: {exc}", flush=True)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        return 1
    finally:
        if sampler is not None:
            sampler.stop()

    elapsed = now() - start_time
    peak_rss_bytes = None
    if sampler is not None:
        peak_rss_bytes = sampler.peak_sum_kb * 1024

    # Update scratch info after the build (size is a read-only observation).
    scratch_info_after = _scratch_info(repo_root, build_dir)
    scratch_info_after["observedBefore"] = scratch_info["observedBefore"]

    report = parser.report(
        swift_invocation=invocation,
        swift_exit_code=exit_code,
        scratch_info=scratch_info_after,
        peak_rss_bytes=peak_rss_bytes,
    )
    report["diagnosticDurationSeconds"] = round(elapsed, 3)
    report["resourceSamples"] = sampler.sample_count if sampler else 0
    print(json.dumps(report, indent=2, sort_keys=True))
    return exit_code


def run_high_output(_repo_root: Path, args: Dict[str, Any]) -> int:
    """Synthetic high-output child used for conductor output-pipeline tests.

    Args:
        args: operation args; may include ``lines``, ``warnings``,
            ``exitCode``, ``linger``.

    Returns:
        The requested exit code.
    """
    lines_arg = args.get("lines")
    lines = max(0, int(lines_arg if lines_arg is not None else 1000))
    warnings_arg = args.get("warnings")
    warnings = max(0, int(warnings_arg if warnings_arg is not None else 0))
    exit_code = int(args.get("exitCode") or 0)
    linger = max(0.0, float(args.get("linger") or 0.0))

    print("==> high-output diagnostic start", flush=True)
    for index in range(lines):
        print(f"high-output line {index}", flush=True)
    for index in range(warnings):
        print(f"Sources/Fake.swift:{index + 1}:1: warning: synthetic warning {index}", flush=True)
    print("==> high-output diagnostic done", flush=True)

    if linger:
        time.sleep(linger)
    return exit_code


def run_diagnostic(kind: str, repo_root: Path, args: Dict[str, Any]) -> int:
    """Entrypoint for the operation_runner dispatch.

    Keeping the switch here means conductor.py only needs to know the name
    and the diagnostic module is free to add more runners.
    """
    if kind == "diagnostics_focused_build":
        return run_focused_build(repo_root, args)
    if kind == "diagnostics_high_output":
        return run_high_output(repo_root, args)
    print(f"unknown diagnostic kind: {kind}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit("run via conductor __operation_runner")
