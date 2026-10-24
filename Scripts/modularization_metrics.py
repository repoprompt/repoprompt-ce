#!/usr/bin/env python3
"""Build-modularization architecture metrics and ratchet checks.

Implements P0.2 (prototype dependency graph) and P0.7 (ratchet baselines) of
docs/migrations/build-modularization-2026-09-28.md.

The dependency graph is a *triage* approximation: comment/string-stripped
sources, unique top-level declaration names, folder-level aggregation. It is
deterministic and build-free so it can gate regressions, but it is not
compiler-grade. For analysis use modularization_index_graph.py, which reads the
index store of a debug build (P0.2; see the ledger for how the two differ).

Usage:
  modularization_metrics.py report [--root DIR] [--details]
  modularization_metrics.py check  [--root DIR] [--baseline FILE]
  modularization_metrics.py update [--root DIR] [--baseline FILE] [--allow-regression]
  modularization_metrics.py edit-locality [--root DIR] [--days 60] [--ref main]
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import subprocess
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = SCRIPT_DIR.parent
DEFAULT_BASELINE = Path("docs/migrations/build-modularization/ratchets.json")

APP_SOURCE_DIR = Path("Sources/RepoPrompt")
APP_TEST_DIR = Path("Tests/RepoPromptTests")
FIRST_PARTY_SOURCE_DIRS = (Path("Sources"), Path("Packages"))

# Lower is better for every metric below.
# Gated: ordinary feature work never needs to worsen these, so CI fails on any increase.
RATCHETED_METRICS: Tuple[str, ...] = (
    "app_files_over_5000_lines",
    "app_files_over_2000_lines",
    "tests_testable_import_app_files",
    "app_static_shared_declarations",
)
# Tracked: reported against the baseline but not gated until the owning wave provides an
# alternative home (a module, an injection seam). Wrong-way edges stay tracked: the regex count is
# too noisy to gate and the index-store count needs a build (ledger, P0.2).
TRACKED_METRICS: Tuple[str, ...] = (
    "app_target_swift_lines",
    "app_shared_accessor_uses",
    "app_userdefaults_standard_uses",
    "app_wrong_way_file_edges",
    "app_largest_cycle_components",
    "tests_sleep_calls",
)

APP_LINE_HEADROOM = 2000

_STRIP_PATTERNS = (
    re.compile(r'"""[\s\S]*?"""'),
    re.compile(r"/\*[\s\S]*?\*/"),
    re.compile(r"//[^\n]*"),
    re.compile(r'"(?:\\.|[^"\\\n])*"'),
)
_TOP_LEVEL_TYPE = re.compile(
    r"^(?:@[\w.]+(?:\([^)\n]*\))?\s+)*"
    r"(?:public |internal |private |fileprivate |final |open |package |nonisolated |indirect )*"
    r"(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)",
    re.M,
)
_TOP_LEVEL_VALUE = re.compile(
    r"^(?:@\w+\s+)*(?:public |internal |private |fileprivate |nonisolated |package )*"
    r"(?:func|let|var)\s+([a-zA-Z_]\w*)",
    re.M,
)
_IDENTIFIER = re.compile(r"\b[A-Za-z_]\w{3,}\b")
_STATIC_SHARED = re.compile(r"\bstatic\s+(?:let|var)\s+shared\b")
_SHARED_USE = re.compile(r"\b[A-Z]\w+\.shared\b")
_USER_DEFAULTS = re.compile(r"\bUserDefaults\.standard\b")
_TESTABLE_APP = re.compile(r"^@testable\s+import\s+RepoPromptApp\b", re.M)
_SLEEP = re.compile(r"\bTask\.sleep\b|\busleep\(|\bThread\.sleep\b|(?<![\w.])sleep\(")

# Triage layering (lower rank = more foundational). Mirrors Appendix A of the plan;
# it is an ordering used to count wrong-way edges, not the target module design.
_LAYER_RULES: Tuple[Tuple[re.Pattern, int], ...] = tuple(
    (re.compile(pattern), rank)
    for pattern, rank in (
        (r"^Infrastructure/(Concurrency|Utilities|Networking|Regex|SyntaxParsing|Security|Telemetry|Process|Diffing)$", 0),
        (r"^Infrastructure/UI", 1),
        (r"^Infrastructure/(FileSystem|Persistence|VCS)$", 2),
        (r"^Infrastructure/WorkspaceContext", 3),
        (r"^Features/(CodeMap|Search)$", 4),
        (r"^Infrastructure/AI", 5),
        (r"^Infrastructure/MCP/ViewModels", 9),
        (r"^Infrastructure/MCP", 6),
        (r"^Features/AgentMode/(Models|Routing|Providers|Runtime|Services|History|Recommendations)$", 7),
        (r"^Features/Settings/Models", 8),
        (r"^Features/Chat/(Models|Services)", 8),
        (r"^Features/(Prompt|ContextBuilder|WorkspaceFiles|Workspaces)$", 8),
        (r"ViewModels", 9),
        (r"Views", 10),
        (r"^Features/Diagnostics", 11),
        (r"^App", 12),
    )
)
_DEEP_AREAS = frozenset(
    {
        "Features/AgentMode",
        "Infrastructure/MCP",
        "Infrastructure/AI",
        "Infrastructure/WorkspaceContext",
        "Infrastructure/UI",
        "Features/Settings",
        "Features/Chat",
    }
)


def strip_swift(text: str) -> str:
    for pattern in _STRIP_PATTERNS:
        text = pattern.sub('""' if pattern.pattern.startswith('"') else "", text)
    return text


def swift_files(directory: Path) -> List[Path]:
    if not directory.is_dir():
        return []
    found = [
        Path(dirpath) / name
        for dirpath, dirnames, filenames in os.walk(directory)
        for name in filenames
        if name.endswith(".swift")
    ]
    return sorted(p for p in found if ".build" not in p.parts)


def component_for(relative: str) -> str:
    parts = relative.split("/")
    if parts[0] == "App":
        return "App" if len(parts) < 3 else f"App/{parts[1]}"
    if len(parts) < 2:
        return parts[0]
    area = f"{parts[0]}/{parts[1]}"
    if area in _DEEP_AREAS and len(parts) > 3:
        return f"{area}/{parts[2]}"
    return area


def layer_rank(component: str) -> Optional[int]:
    for pattern, rank in _LAYER_RULES:
        if pattern.search(component):
            return rank
    return None


def count_lines(text: str) -> int:
    return text.count("\n") + (0 if text.endswith("\n") or not text else 1)


class SourceSet:
    def __init__(self, root: Path, directory: Path) -> None:
        self.base = root / directory
        self.raw: Dict[str, str] = {}
        self.stripped: Dict[str, str] = {}
        for path in swift_files(self.base):
            rel = path.relative_to(self.base).as_posix()
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.raw[rel] = text
            self.stripped[rel] = strip_swift(text)


def declaration_index(sources: SourceSet) -> Dict[str, Set[str]]:
    index: Dict[str, Set[str]] = collections.defaultdict(set)
    for rel, text in sources.stripped.items():
        for name in _TOP_LEVEL_TYPE.findall(text):
            if len(name) >= 5:
                index[name].add(rel)
        for name in _TOP_LEVEL_VALUE.findall(text):
            if len(name) >= 6:
                index[name].add(rel)
    return index


def file_edges(sources: SourceSet, index: Mapping[str, Set[str]]) -> Dict[str, Set[str]]:
    edges: Dict[str, Set[str]] = {}
    for rel, text in sources.stripped.items():
        targets: Set[str] = set()
        for name in set(_IDENTIFIER.findall(text)):
            owners = index.get(name)
            if owners and len(owners) <= 2:
                targets.update(owner for owner in owners if owner != rel)
        edges[rel] = targets
    return edges


def strongly_connected_components(graph: Mapping[str, Iterable[str]]) -> List[List[str]]:
    """Iterative Tarjan so large graphs never hit the recursion limit."""
    index_of: Dict[str, int] = {}
    low: Dict[str, int] = {}
    on_stack: Set[str] = set()
    stack: List[str] = []
    result: List[List[str]] = []
    counter = 0
    for start in sorted(graph):
        if start in index_of:
            continue
        work: List[Tuple[str, Iterable[str]]] = [(start, iter(sorted(graph.get(start, ()))))]
        index_of[start] = low[start] = counter
        counter += 1
        stack.append(start)
        on_stack.add(start)
        while work:
            node, children = work[-1]
            advanced = False
            for child in children:
                if child not in index_of:
                    index_of[child] = low[child] = counter
                    counter += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, iter(sorted(graph.get(child, ())))))
                    advanced = True
                    break
                if child in on_stack:
                    low[node] = min(low[node], index_of[child])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index_of[node]:
                component: List[str] = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                result.append(sorted(component))
    return result


def graph_metrics(sources: SourceSet) -> Tuple[Dict[str, int], Dict[str, object]]:
    index = declaration_index(sources)
    edges = file_edges(sources, index)
    component_graph: Dict[str, Set[str]] = collections.defaultdict(set)
    wrong_way = 0
    wrong_way_targets: collections.Counter = collections.Counter()
    for source, targets in edges.items():
        source_component = component_for(source)
        component_graph.setdefault(source_component, set())
        source_rank = layer_rank(source_component)
        for target in targets:
            target_component = component_for(target)
            if target_component == source_component:
                continue
            component_graph[source_component].add(target_component)
            target_rank = layer_rank(target_component)
            if source_rank is not None and target_rank is not None and target_rank > source_rank:
                wrong_way += 1
                wrong_way_targets[target] += 1
    sccs = strongly_connected_components(component_graph)
    largest = max((len(c) for c in sccs), default=0)
    metrics = {
        "app_wrong_way_file_edges": wrong_way,
        "app_largest_cycle_components": largest if largest > 1 else 0,
        "app_components": len(component_graph),
    }
    details = {
        "top_wrong_way_targets": [
            {"file": name, "edges": count}
            for name, count in sorted(wrong_way_targets.items(), key=lambda item: (-item[1], item[0]))[:40]
        ],
        "largest_cycle": max(sccs, key=len) if sccs else [],
    }
    return metrics, details


def collect(root: Path) -> Tuple[Dict[str, int], Dict[str, object]]:
    app = SourceSet(root, APP_SOURCE_DIR)
    tests = SourceSet(root, APP_TEST_DIR)
    app_lines = {rel: count_lines(text) for rel, text in app.raw.items()}
    first_party_lines = 0
    for directory in FIRST_PARTY_SOURCE_DIRS:
        for path in swift_files(root / directory):
            if "Tests" in path.relative_to(root).parts:
                continue
            first_party_lines += count_lines(path.read_text(encoding="utf-8", errors="ignore"))
    app_total = sum(app_lines.values())

    def total(pattern: re.Pattern, texts: Iterable[str]) -> int:
        return sum(len(pattern.findall(text)) for text in texts)

    metrics: Dict[str, int] = {
        "app_target_swift_files": len(app_lines),
        "app_target_swift_lines": app_total,
        "first_party_swift_lines": first_party_lines,
        "app_share_permille": (app_total * 1000 // first_party_lines) if first_party_lines else 0,
        "app_files_over_2000_lines": sum(1 for n in app_lines.values() if n > 2000),
        "app_files_over_5000_lines": sum(1 for n in app_lines.values() if n > 5000),
        "app_static_shared_declarations": total(_STATIC_SHARED, app.stripped.values()),
        "app_shared_accessor_uses": total(_SHARED_USE, app.stripped.values()),
        "app_userdefaults_standard_uses": total(_USER_DEFAULTS, app.stripped.values()),
        "tests_testable_import_app_files": sum(1 for text in tests.raw.values() if _TESTABLE_APP.search(text)),
        "tests_sleep_calls": total(_SLEEP, tests.stripped.values()),
    }
    graph, details = graph_metrics(app)
    metrics.update(graph)
    details["largest_files"] = [
        {"file": rel, "lines": n}
        for rel, n in sorted(app_lines.items(), key=lambda item: (-item[1], item[0]))[:25]
    ]
    return dict(sorted(metrics.items())), details


def regressions(current: Mapping[str, int], baseline: Mapping[str, int]) -> List[str]:
    problems = []
    if "app_target_swift_lines" not in baseline:
        problems.append("app_target_swift_lines: missing from baseline")
    for name in RATCHETED_METRICS:
        if name not in baseline:
            problems.append(f"{name}: missing from baseline")
        elif current.get(name, 0) > baseline[name]:
            problems.append(f"{name}: {current.get(name, 0)} > baseline {baseline[name]}")
    return problems


def app_line_advisory(current: Mapping[str, int], baseline: Mapping[str, int]) -> Optional[str]:
    """Report App-line excess without weakening required baseline or other ratchet checks."""
    if "app_target_swift_lines" not in baseline:
        return None
    actual = current.get("app_target_swift_lines", 0)
    reference = baseline["app_target_swift_lines"] + APP_LINE_HEADROOM
    if actual <= reference:
        return None
    return (
        f"app_target_swift_lines: {actual} > reference {reference} "
        f"(excess {actual - reference}; not gated)"
    )


def baseline_raises(current: Mapping[str, int], baseline: Mapping[str, int]) -> List[str]:
    """Every ratcheted or tracked value `update` would raise, including advisory App lines."""
    return [
        f"{name}: {baseline[name]} -> {current.get(name, 0)}"
        for name in dict.fromkeys(("app_target_swift_lines",) + RATCHETED_METRICS + TRACKED_METRICS)
        if name in baseline and current.get(name, 0) > baseline[name]
    ]


def improvements(current: Mapping[str, int], baseline: Mapping[str, int]) -> List[str]:
    return [
        f"{name}: {baseline[name]} -> {current[name]}"
        for name in RATCHETED_METRICS + TRACKED_METRICS
        if name in baseline and current.get(name, 0) < baseline[name]
    ]


def tracked_drift(current: Mapping[str, int], baseline: Mapping[str, int]) -> List[str]:
    return [
        f"{name}: {baseline[name]} -> {current[name]}"
        for name in TRACKED_METRICS
        if name in baseline and current.get(name, 0) > baseline[name]
    ]


def load_baseline(path: Path) -> Dict[str, int]:
    document = json.loads(path.read_text(encoding="utf-8"))
    return {k: int(v) for k, v in document["metrics"].items()}


def write_baseline(path: Path, metrics: Mapping[str, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "description": (
            "Build-modularization ratchet baselines. Ratcheted metrics may only decrease; "
            "regenerate with `python3 Scripts/modularization_metrics.py update` after an improving slice. "
            "App Swift lines above baseline plus headroom are advisory, not a failing gate."
        ),
        "ratcheted": list(RATCHETED_METRICS),
        "app_target_swift_lines_headroom": APP_LINE_HEADROOM,
        "tracked": list(TRACKED_METRICS),
        "metrics": dict(sorted(metrics.items())),
    }
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def edit_locality(root: Path, ref: str = "origin/main", days: int = 60) -> Dict[str, object]:
    """Classify trailing Swift touches by *current* owner, following Git renames backward."""
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).isoformat()
    completed = subprocess.run(
        ["git", "log", ref, f"--since={since}", "-M", "--format=commit:%H", "--name-status", "--", "Sources"],
        cwd=root, check=True, capture_output=True, text=True,
    )
    catalog = json.loads((root / "Scripts/modularization/modules.json").read_text(encoding="utf-8"))
    modules = catalog["modules"]
    roots = sorted(
        ((entry["source_root"].rstrip("/") + "/", name) for name, entry in modules.items()
         if entry.get("source_root", "").startswith("Sources/")),
        key=lambda row: -len(row[0]),
    )

    def path_owner(path: str) -> Optional[str]:
        return next((name for prefix, name in roots if path.startswith(prefix)), None)

    # A moved file's old app path belongs to its new module for this metric.
    owners = {
        path.relative_to(root).as_posix(): name
        for prefix, name in roots
        for path in swift_files(root / prefix.rstrip('/'))
    }
    touches = collections.Counter()
    commits = 0
    changes: List[Tuple[str, List[str]]] = []

    def count_commit() -> None:
        nonlocal changes
        if not changes:
            return
        for status, paths in changes:
            current_path = paths[-1]
            if not current_path.endswith('.swift'):
                continue
            owner = owners.get(current_path) or path_owner(current_path)
            if owner:
                touches[owner] += 1
        for status, paths in changes:
            if status.startswith(('R', 'C')) and len(paths) == 2:
                old, new = paths
                owner = owners.pop(new, None)
                if owner:
                    owners[old] = owner
            elif status.startswith('A'):
                owners.pop(paths[-1], None)
        changes = []

    for line in completed.stdout.splitlines():
        if line.startswith('commit:'):
            count_commit()
            commits += 1
        elif line and '\t' in line:
            status, *paths = line.split('\t')
            changes.append((status, paths))
    count_commit()
    local = sum(count for name, count in touches.items() if modules[name].get("app_free_tests"))
    total = sum(touches.values())
    return {
        "ref": ref, "days": days, "commits": commits, "swift_file_touches": total,
        "app_free_test_touches": local, "edit_locality_percent": round(100 * local / total, 2) if total else 0.0,
        "by_module": dict(sorted(touches.items())),
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("report", "check", "update", "edit-locality"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--details", action="store_true", help="report: include top offenders")
    parser.add_argument("--allow-regression", action="store_true", help="update: accept a worse baseline")
    parser.add_argument("--days", type=int, default=60, help="edit-locality: trailing days")
    parser.add_argument("--ref", default="origin/main", help="edit-locality: Git ref (default origin/main)")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    baseline_path = args.baseline or (root / DEFAULT_BASELINE)
    if args.command == "edit-locality":
        if args.days < 1:
            parser.error("--days must be positive")
        print(json.dumps(edit_locality(root, args.ref, args.days), indent=2))
        return 0

    metrics, details = collect(root)

    if args.command == "report":
        output: Dict[str, object] = {"metrics": metrics}
        if args.details:
            output["details"] = details
        print(json.dumps(output, indent=2))
        return 0

    if args.command == "check":
        if not baseline_path.is_file():
            print(f"modularization ratchets: missing baseline {baseline_path}", file=sys.stderr)
            return 1
        baseline = load_baseline(baseline_path)
        advisory = app_line_advisory(metrics, baseline)
        if advisory:
            print("modularization advisory: " + advisory)
        problems = regressions(metrics, baseline)
        if problems:
            print("modularization ratchets regressed:", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1
        drift = tracked_drift(metrics, baseline)
        if drift:
            print("modularization tracked metrics grew (not gated): " + "; ".join(drift))
        better = improvements(metrics, baseline)
        print("modularization ratchets: ok" + (" (improved; run update: " + "; ".join(better) + ")" if better else ""))
        return 0

    if baseline_path.is_file() and not args.allow_regression:
        baseline = load_baseline(baseline_path)
        problems = regressions(metrics, baseline) + baseline_raises(metrics, baseline)
        if problems:
            print("refusing to raise baseline (use --allow-regression with justification):", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1
    write_baseline(baseline_path, metrics)
    print(f"wrote {baseline_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
