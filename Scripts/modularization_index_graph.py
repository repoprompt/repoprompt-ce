#!/usr/bin/env python3
"""Compiler-grade file dependency graph for RepoPromptApp, read from the SwiftPM index store.

Implements P0.2 of docs/migrations/build-modularization-2026-09-28.md. It replaces the
regex triage graph in modularization_metrics.py for analysis. That graph keeps feeding
the build-free ratchets.

Source of truth: the index store a debug `swift build` writes
(`.build/out` for Swift Build or `.build/<triple>/debug/index/store`). It is read through the toolchain's
`libIndexStore.dylib` with ctypes, so no package or pip dependency is needed.

For each `RepoPromptApp` source file the tool takes the newest index unit, then reads that
unit's record. A file *defines* every symbol USR it declares or defines. It *references*
every USR it has a reference occurrence of. A file→file edge exists when file A references
a USR that file B (B != A) defines. Components, layers, and SCCs reuse the triage
definitions in modularization_metrics.py, so the two graphs are directly comparable.

Usage:
  modularization_index_graph.py dump      --output FILE [--store DIR]
  modularization_index_graph.py report    [--graph FILE | --store DIR] [--top N]
  modularization_index_graph.py readiness --files PATH [PATH ...] [--graph FILE | --store DIR]
  modularization_index_graph.py compare   [--graph FILE | --store DIR] [--top N]
  modularization_index_graph.py edge      SOURCE TARGET [--graph FILE | --store DIR]

Paths are relative to Sources/RepoPrompt (repository-relative paths are also accepted).
Build through conductor, for example `./conductor swift-build --product RepoPrompt`.
Conductor records source-content SHA-256 hashes for a successful stable build; without
that build fingerprint, freshness is unknown rather than inferred from timestamps.
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Set, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import modularization_metrics as mm  # noqa: E402

DEFAULT_ROOT = SCRIPT_DIR.parent
DEFAULT_MODULE = "RepoPromptApp"
GRAPH_VERSION = 1
BUILD_FINGERPRINT = Path(".build/modularization/app-source-sha256.json")

# indexstore_symbol_role_t
ROLE_DECLARATION = 1 << 0
ROLE_DEFINITION = 1 << 1
ROLE_REFERENCE = 1 << 2
ROLE_IMPLICIT = 1 << 8
# indexstore_unit_dependency_kind_t
UNIT_DEPENDENCY_UNIT = 1
UNIT_DEPENDENCY_RECORD = 2

SYMBOL_KINDS = {
    0: "unknown", 1: "module", 2: "namespace", 3: "namespace-alias", 4: "macro", 5: "enum",
    6: "struct", 7: "class", 8: "protocol", 9: "extension", 10: "union", 11: "typealias",
    12: "function", 13: "variable", 14: "field", 15: "enum-case", 16: "instance-method",
    17: "class-method", 18: "static-method", 19: "instance-property", 20: "class-property",
    21: "static-property", 22: "constructor", 23: "destructor", 24: "conversion-function",
    25: "parameter", 26: "using", 27: "concept", 1000: "comment-tag",
}
TYPE_KINDS = frozenset({"enum", "struct", "class", "protocol", "typealias", "union"})
MEMBER_KINDS = frozenset(
    {
        "field", "enum-case", "instance-method", "class-method", "static-method", "instance-property",
        "class-property", "static-property", "constructor", "destructor", "conversion-function",
    }
)
_ACCESSOR_PREFIX = re.compile(r"^(?:getter|setter|_modify|_read|willSet|didSet|init|mutableAddress|unsafeAddress):")


# --------------------------------------------------------------------------------------
# Index store access
# --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Unit:
    main_file: str
    module: str
    mtime: float
    records: Tuple[str, ...]
    imports: Tuple[str, ...]  # non-system module dependencies


@dataclass(frozen=True)
class Occurrence:
    roles: int
    usr: str
    name: str
    kind: str


class IndexStoreError(RuntimeError):
    pass


def default_library_path() -> Optional[Path]:
    override = os.environ.get("REPOPROMPT_LIBINDEXSTORE")
    if override:
        return Path(override)
    try:
        swift = subprocess.run(
            ["xcrun", "--find", "swift"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    candidate = Path(swift).resolve().parent.parent / "lib" / "libIndexStore.dylib"
    return candidate if candidate.is_file() else None


def default_store_path(root: Path) -> Optional[Path]:
    swiftbuild = root / ".build/out"
    if (swiftbuild / "v5/units").is_dir():
        return swiftbuild
    candidates = sorted(root.glob(".build/*/debug/index/store"))
    return candidates[0] if candidates else None


class IndexStore:
    """Minimal ctypes binding over libIndexStore's function-pointer (`*_apply_f`) C API."""

    def __init__(self, store_path: Path, library_path: Path) -> None:
        lib = ctypes.CDLL(str(library_path))

        class StringRef(ctypes.Structure):
            _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_size_t)]

        vp, cp, u64 = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64
        err = ctypes.POINTER(ctypes.c_void_p)
        self._unit_cb = ctypes.CFUNCTYPE(ctypes.c_bool, vp, StringRef)
        self._ptr_cb = ctypes.CFUNCTYPE(ctypes.c_bool, vp, vp)

        def bind(name: str, restype, *argtypes) -> Callable:
            fn = getattr(lib, name)
            fn.restype = restype
            fn.argtypes = list(argtypes)
            return fn

        self._error_description = bind("indexstore_error_get_description", cp, vp)
        self._error_dispose = bind("indexstore_error_dispose", None, vp)
        store_create = bind("indexstore_store_create", vp, cp, err)
        self._store_dispose = bind("indexstore_store_dispose", None, vp)
        self._units_apply = bind("indexstore_store_units_apply_f", ctypes.c_bool, vp, ctypes.c_uint, vp, self._unit_cb)
        self._unit_create = bind("indexstore_unit_reader_create", vp, vp, cp, err)
        self._unit_dispose = bind("indexstore_unit_reader_dispose", None, vp)
        self._unit_main_file = bind("indexstore_unit_reader_get_main_file", StringRef, vp)
        self._unit_module = bind("indexstore_unit_reader_get_module_name", StringRef, vp)
        self._unit_mtime = bind(
            "indexstore_unit_reader_get_modification_time", None, vp, ctypes.POINTER(ctypes.c_int64), ctypes.POINTER(ctypes.c_int64)
        )
        self._deps_apply = bind("indexstore_unit_reader_dependencies_apply_f", ctypes.c_bool, vp, vp, self._ptr_cb)
        self._dep_kind = bind("indexstore_unit_dependency_get_kind", ctypes.c_int, vp)
        self._dep_name = bind("indexstore_unit_dependency_get_name", StringRef, vp)
        self._dep_module = bind("indexstore_unit_dependency_get_modulename", StringRef, vp)
        self._dep_is_system = bind("indexstore_unit_dependency_is_system", ctypes.c_bool, vp)
        self._record_create = bind("indexstore_record_reader_create", vp, vp, cp, err)
        self._record_dispose = bind("indexstore_record_reader_dispose", None, vp)
        self._occurrences_apply = bind("indexstore_record_reader_occurrences_apply_f", ctypes.c_bool, vp, vp, self._ptr_cb)
        self._occ_symbol = bind("indexstore_occurrence_get_symbol", vp, vp)
        self._occ_roles = bind("indexstore_occurrence_get_roles", u64, vp)
        self._sym_usr = bind("indexstore_symbol_get_usr", StringRef, vp)
        self._sym_name = bind("indexstore_symbol_get_name", StringRef, vp)
        self._sym_kind = bind("indexstore_symbol_get_kind", ctypes.c_int, vp)

        error = ctypes.c_void_p()
        self._store = store_create(str(store_path).encode(), ctypes.byref(error))
        if not self._store:
            raise IndexStoreError(f"cannot open index store {store_path}: {self._consume_error(error)}")

    @staticmethod
    def _string(ref) -> str:
        return ctypes.string_at(ref.data, ref.length).decode("utf-8", "replace") if ref.length else ""

    def _consume_error(self, error: ctypes.c_void_p) -> str:
        if not error:
            return "unknown error"
        message = (self._error_description(error) or b"").decode("utf-8", "replace")
        self._error_dispose(error)
        return message

    def close(self) -> None:
        if self._store:
            self._store_dispose(self._store)
            self._store = None

    def units(self) -> Iterator[Unit]:
        names: List[str] = []

        def on_unit(_context, name) -> bool:
            names.append(self._string(name))
            return True

        callback = self._unit_cb(on_unit)
        self._units_apply(self._store, 0, None, callback)
        for name in names:
            error = ctypes.c_void_p()
            reader = self._unit_create(self._store, name.encode(), ctypes.byref(error))
            if not reader:
                self._consume_error(error)
                continue
            try:
                seconds, nanoseconds = ctypes.c_int64(), ctypes.c_int64()
                self._unit_mtime(reader, ctypes.byref(seconds), ctypes.byref(nanoseconds))
                records: List[str] = []
                imports: List[str] = []

                def on_dependency(_context, dependency) -> bool:
                    kind = self._dep_kind(dependency)
                    if kind == UNIT_DEPENDENCY_RECORD:
                        records.append(self._string(self._dep_name(dependency)))
                    elif kind == UNIT_DEPENDENCY_UNIT and not self._dep_is_system(dependency):
                        module = self._string(self._dep_module(dependency))
                        if module:
                            imports.append(module)
                    return True

                dep_callback = self._ptr_cb(on_dependency)
                self._deps_apply(reader, None, dep_callback)
                yield Unit(
                    main_file=self._string(self._unit_main_file(reader)),
                    module=self._string(self._unit_module(reader)),
                    mtime=seconds.value + nanoseconds.value / 1e9,
                    records=tuple(records),
                    imports=tuple(sorted(set(imports))),
                )
            finally:
                self._unit_dispose(reader)

    def occurrences(self, record: str) -> List[Occurrence]:
        error = ctypes.c_void_p()
        reader = self._record_create(self._store, record.encode(), ctypes.byref(error))
        if not reader:
            raise IndexStoreError(f"cannot read record {record}: {self._consume_error(error)}")
        found: List[Occurrence] = []
        wanted = ROLE_DECLARATION | ROLE_DEFINITION | ROLE_REFERENCE

        def on_occurrence(_context, occurrence) -> bool:
            roles = self._occ_roles(occurrence)
            if roles & wanted:
                symbol = self._occ_symbol(occurrence)
                found.append(
                    Occurrence(
                        roles=roles,
                        usr=self._string(self._sym_usr(symbol)),
                        name=self._string(self._sym_name(symbol)),
                        kind=SYMBOL_KINDS.get(self._sym_kind(symbol), "unknown"),
                    )
                )
            return True

        try:
            callback = self._ptr_cb(on_occurrence)
            self._occurrences_apply(reader, None, callback)
        finally:
            self._record_dispose(reader)
        return found


# --------------------------------------------------------------------------------------
# Extraction: index store -> graph document (pure over the store interface)
# --------------------------------------------------------------------------------------


def base_name(name: str) -> str:
    return _ACCESSOR_PREFIX.sub("", name).split("(", 1)[0]


def source_hashes(root: Path, source_dir: Path = mm.APP_SOURCE_DIR) -> Dict[str, str]:
    return {
        path.relative_to(root / source_dir).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in mm.swift_files(root / source_dir)
    }


def build_source_hashes(root: Path) -> Optional[Dict[str, str]]:
    try:
        document = json.loads((root / BUILD_FINGERPRINT).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    expected = document.get("source_sha256") if isinstance(document, dict) else None
    if not isinstance(expected, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in expected.items()):
        return None
    return expected


def extract_graph(store, root: Path, module: str = DEFAULT_MODULE, source_dir: Path = mm.APP_SOURCE_DIR,
                  built_source_sha256: Optional[Mapping[str, str]] = None) -> Dict[str, object]:
    """Build the graph document from any object with `units()` and `occurrences(record)`."""
    source_base = Path(os.path.realpath(root / source_dir))
    chosen: Dict[str, Unit] = {}
    missing_sources: Set[str] = set()
    for unit in store.units():
        if unit.module != module or not unit.records or not unit.main_file:
            continue
        main = Path(os.path.realpath(unit.main_file))
        try:
            rel = main.relative_to(source_base).as_posix()
        except ValueError:
            continue
        if not main.is_file():
            missing_sources.add(rel)
            continue
        previous = chosen.get(rel)
        if previous is None or unit.mtime > previous.mtime:
            chosen[rel] = unit

    files: Dict[str, Dict[str, object]] = {}
    symbols: Dict[str, Dict[str, str]] = {}
    raw_references: Dict[str, collections.Counter] = {}
    explicit: Dict[str, Set[str]] = {}
    for rel in sorted(chosen):
        definitions: Set[str] = set()
        references: collections.Counter = collections.Counter()
        explicit_usrs: Set[str] = set()
        for record in chosen[rel].records:
            for occurrence in store.occurrences(record):
                if not occurrence.usr:
                    continue
                if occurrence.roles & (ROLE_DECLARATION | ROLE_DEFINITION):
                    definitions.add(occurrence.usr)
                    symbols.setdefault(occurrence.usr, {"name": occurrence.name, "kind": occurrence.kind})
                if occurrence.roles & ROLE_REFERENCE:
                    references[occurrence.usr] += 1
                    if not occurrence.roles & ROLE_IMPLICIT:
                        explicit_usrs.add(occurrence.usr)
                    symbols.setdefault(occurrence.usr, {"name": occurrence.name, "kind": occurrence.kind})
        files[rel] = {"definitions": sorted(definitions), "imports": [m for m in chosen[rel].imports if m != module]}
        raw_references[rel] = references
        explicit[rel] = explicit_usrs

    defined = {usr for data in files.values() for usr in data["definitions"]}  # type: ignore[union-attr]
    for rel, data in files.items():
        refs = raw_references[rel]
        data["references"] = {usr: refs[usr] for usr in sorted(refs) if usr in defined}
        data["implicit_only"] = sorted(usr for usr in refs if usr in defined and usr not in explicit[rel])
        data["external_reference_names"] = sorted(
            {base_name(symbols[usr]["name"]) for usr in refs if usr not in defined and symbols[usr]["name"]}
        )
    for usr in list(symbols):
        if usr not in defined:
            del symbols[usr]

    sources = {path.relative_to(root / source_dir).as_posix(): path for path in mm.swift_files(root / source_dir)}
    actual_hashes = source_hashes(root, source_dir)
    expected_hashes = dict(built_source_sha256) if built_source_sha256 is not None else build_source_hashes(root)
    stale = sorted(rel for rel, digest in actual_hashes.items() if rel in chosen and expected_hashes is not None and expected_hashes.get(rel) != digest)
    return {
        "version": GRAPH_VERSION,
        "module": module,
        "source_dir": source_dir.as_posix(),
        "files": files,
        "symbols": symbols,
        "freshness": {
            "indexed_files": len(chosen),
            "source_files": len(sources),
            "unindexed_files": sorted(set(sources) - set(chosen)),
            "stale_files": stale,
            "index_units_for_deleted_files": len(missing_sources),
            "source_sha256": expected_hashes,
            "freshness_unknown": expected_hashes is None,
            "current": expected_hashes is not None and not stale and set(sources) == set(chosen)
                       and set(actual_hashes) == set(expected_hashes),
        },
    }


# --------------------------------------------------------------------------------------
# Analysis over a graph document
# --------------------------------------------------------------------------------------


def definers(document: Mapping[str, object]) -> Dict[str, Set[str]]:
    owners: Dict[str, Set[str]] = collections.defaultdict(set)
    for rel, data in document["files"].items():  # type: ignore[union-attr]
        for usr in data["definitions"]:
            owners[usr].add(rel)
    return owners


def file_edges(document: Mapping[str, object]) -> Dict[str, Dict[str, Dict[str, int]]]:
    """source file -> target file -> {usr: reference count}."""
    owners = definers(document)
    edges: Dict[str, Dict[str, Dict[str, int]]] = {}
    for rel, data in document["files"].items():  # type: ignore[union-attr]
        targets: Dict[str, Dict[str, int]] = collections.defaultdict(dict)
        for usr, count in data["references"].items():
            for owner in owners.get(usr, ()):
                if owner != rel:
                    targets[owner][usr] = count
        edges[rel] = dict(targets)
    return edges


def wrong_way_pairs(edges: Mapping[str, Iterable[str]]) -> Set[Tuple[str, str]]:
    pairs: Set[Tuple[str, str]] = set()
    for source, targets in edges.items():
        source_component = mm.component_for(source)
        source_rank = mm.layer_rank(source_component)
        if source_rank is None:
            continue
        for target in targets:
            target_component = mm.component_for(target)
            if target_component == source_component:
                continue
            target_rank = mm.layer_rank(target_component)
            if target_rank is not None and target_rank > source_rank:
                pairs.add((source, target))
    return pairs


def component_graph(edges: Mapping[str, Iterable[str]]) -> Dict[str, Set[str]]:
    graph: Dict[str, Set[str]] = collections.defaultdict(set)
    for source, targets in edges.items():
        source_component = mm.component_for(source)
        graph.setdefault(source_component, set())
        for target in targets:
            target_component = mm.component_for(target)
            if target_component != source_component:
                graph[source_component].add(target_component)
    return graph


def ranked(counter: Mapping[str, int], top: int) -> List[Dict[str, object]]:
    return [
        {"file": name, "edges": count}
        for name, count in sorted(counter.items(), key=lambda item: (-item[1], item[0]))[:top]
    ]


def analyze(document: Mapping[str, object], top: int = 40) -> Dict[str, object]:
    edges = file_edges(document)
    simple = {source: set(targets) for source, targets in edges.items()}
    pairs = wrong_way_pairs(simple)
    targets = collections.Counter(target for _, target in pairs)
    components = component_graph(simple)
    component_sccs = mm.strongly_connected_components(components)
    largest = max(component_sccs, key=len) if component_sccs else []
    file_sccs = [scc for scc in mm.strongly_connected_components(simple) if len(scc) > 1]
    owners = definers(document)
    implicit_only_edges = 0
    for source, by_target in edges.items():
        implicit = set(document["files"][source]["implicit_only"])  # type: ignore[index]
        implicit_only_edges += sum(1 for usrs in by_target.values() if set(usrs) <= implicit)
    metrics = {
        "index_files": len(edges),
        "index_file_edges": sum(len(t) for t in edges.values()),
        "index_implicit_only_file_edges": implicit_only_edges,
        "index_multiply_defined_symbols": sum(1 for files in owners.values() if len(files) > 1),
        "index_wrong_way_file_edges": len(pairs),
        "index_wrong_way_target_files": len(targets),
        "index_components": len(components),
        "index_largest_cycle_components": len(largest) if len(largest) > 1 else 0,
        "index_file_cycles": len(file_sccs),
        "index_largest_file_cycle": max((len(s) for s in file_sccs), default=0),
    }
    total = len(pairs) or 1
    top_targets = ranked(targets, top)
    covered = sum(entry["edges"] for entry in top_targets)  # type: ignore[misc]
    return {
        "metrics": metrics,
        "top_wrong_way_targets": top_targets,
        "top_targets_share_permille": covered * 1000 // total,
        "largest_cycle": largest if len(largest) > 1 else [],
        "components_outside_largest_cycle": sorted(set(components) - set(largest)),
        "freshness": document.get("freshness", {}),
    }


def resolve_file_set(document: Mapping[str, object], paths: Sequence[str]) -> Tuple[Set[str], List[str]]:
    source_dir = str(document.get("source_dir", mm.APP_SOURCE_DIR.as_posix())).rstrip("/") + "/"
    known = set(document["files"])  # type: ignore[arg-type]
    selected: Set[str] = set()
    unmatched: List[str] = []
    for raw in paths:
        path = raw.strip().rstrip("/")
        if path.startswith(source_dir):
            path = path[len(source_dir):]
        matches = {rel for rel in known if rel == path or rel.startswith(path + "/")}
        if matches:
            selected |= matches
        else:
            unmatched.append(raw)
    return selected, unmatched


def symbol_label(document: Mapping[str, object], usr: str) -> str:
    symbol = document["symbols"].get(usr, {})  # type: ignore[union-attr]
    return f"{symbol.get('name', usr)} [{symbol.get('kind', '?')}]"


def is_accessor(document: Mapping[str, object], usr: str) -> bool:
    name = document["symbols"].get(usr, {}).get("name", "")  # type: ignore[union-attr]
    return bool(_ACCESSOR_PREFIX.match(name))


def readiness(document: Mapping[str, object], paths: Sequence[str], limit: int = 12) -> Dict[str, object]:
    """References from a candidate file set to app files outside it (accessors fold into their property)."""
    selected, unmatched = resolve_file_set(document, paths)
    edges = file_edges(document)
    outbound: Dict[str, Dict[str, object]] = {}
    inbound_symbols: collections.Counter = collections.Counter()
    inbound_files: Set[str] = set()
    for source, by_target in edges.items():
        for target, usrs in by_target.items():
            named = {usr: count for usr, count in usrs.items() if not is_accessor(document, usr)}
            if source in selected and target not in selected:
                entry = outbound.setdefault(target, {"from": set(), "symbols": collections.Counter()})
                entry["from"].add(source)  # type: ignore[union-attr]
                entry["symbols"].update(named)  # type: ignore[union-attr]
            elif source not in selected and target in selected:
                inbound_files.add(source)
                inbound_symbols.update(named)
    imports = sorted(
        {m for rel in selected for m in document["files"][rel]["imports"]}  # type: ignore[index]
    )
    blockers = sorted(outbound.items(), key=lambda item: (-len(item[1]["from"]), item[0]))  # type: ignore[arg-type]
    freshness = document.get("freshness", {})
    coverage_complete = (isinstance(freshness, dict) and
                         isinstance(freshness.get("source_sha256"), dict) and
                         freshness.get("source_files") == len(document["files"]) and
                         not freshness.get("unindexed_files") and
                         not freshness.get("stale_files") and
                         freshness.get("current", True) is not False)
    return {
        "files": len(selected),
        "unmatched_paths": unmatched,
        "ready": not outbound and not unmatched and bool(selected) and coverage_complete,
        "coverage_complete": coverage_complete,
        "freshness": freshness,
        "outbound_target_files": len(outbound),
        "outbound_file_edges": sum(len(entry["from"]) for entry in outbound.values()),  # type: ignore[arg-type]
        "outbound_symbols": len({usr for entry in outbound.values() for usr in entry["symbols"]}),  # type: ignore[union-attr]
        "blockers": [
            {
                "target": target,
                "component": mm.component_for(target),
                "from_files": len(entry["from"]),  # type: ignore[arg-type]
                "symbols": [
                    symbol_label(document, usr)
                    for usr, _ in entry["symbols"].most_common(limit)  # type: ignore[union-attr]
                ],
            }
            for target, entry in blockers
        ],
        "module_imports": imports,
        "inbound_files": len(inbound_files),
        "inbound_symbols_needing_access": len(inbound_symbols),
        "top_inbound_symbols": [symbol_label(document, usr) for usr, _ in inbound_symbols.most_common(limit)],
    }


def edge_detail(document: Mapping[str, object], source: str, target: str) -> Dict[str, object]:
    source_rel = _single(document, source)
    target_rel = _single(document, target)
    usrs = file_edges(document).get(source_rel, {}).get(target_rel, {})
    implicit = set(document["files"][source_rel]["implicit_only"])  # type: ignore[index]
    return {
        "source": source_rel,
        "target": target_rel,
        "wrong_way": (source_rel, target_rel) in wrong_way_pairs({source_rel: {target_rel}}),
        "symbols": [
            {"symbol": symbol_label(document, usr), "references": count, "implicit_only": usr in implicit}
            for usr, count in sorted(usrs.items(), key=lambda item: (-item[1], item[0]))
        ],
    }


def _single(document: Mapping[str, object], path: str) -> str:
    selected, _ = resolve_file_set(document, [path])
    if len(selected) != 1:
        raise SystemExit(f"{path!r} must name exactly one indexed file (matched {len(selected)})")
    return next(iter(selected))


# --------------------------------------------------------------------------------------
# Validation against the regex prototype
# --------------------------------------------------------------------------------------

# Why the regex graph misses an edge the index has, most regex-visible reason first.
_MISSED_ORDER = (
    "top-level name the regex also declares",
    "name declared in more than two files (regex drops ambiguous names)",
    "type the regex cannot see (nested, indented under #if, or name under 5 characters)",
    "member or extension member (the regex indexes top-level names only)",
    "other symbol",
)
# Why the regex graph has an edge the index does not.
_EXTRA_ORDER = (
    "identifier resolves to a different app declaration (same name)",
    "identifier resolves to a declaration in another module (same name)",
    "no indexed symbol with that name (local, parameter, argument label, or inactive #if code)",
)


def classify_index_only(document, regex_index, source: str, target: str, usrs: Iterable[str]) -> str:
    best = len(_MISSED_ORDER) - 1
    for usr in usrs:
        symbol = document["symbols"].get(usr, {})
        name, kind = base_name(symbol.get("name", "")), symbol.get("kind", "")
        owners = regex_index.get(name, set())
        if target in owners and len(owners) <= 2:
            rank = 0
        elif target in owners:
            rank = 1
        elif kind in TYPE_KINDS:
            rank = 2
        elif kind in MEMBER_KINDS or usr.startswith("s:e:"):
            rank = 3
        else:
            rank = 4
        best = min(best, rank)
    return _MISSED_ORDER[best]


def classify_regex_only(document, regex_index, stripped: str, source: str, target: str) -> Tuple[str, List[str]]:
    names = sorted(
        name
        for name in set(mm._IDENTIFIER.findall(stripped))
        if target in regex_index.get(name, ()) and len(regex_index[name]) <= 2
    )
    data = document["files"].get(source)
    if data is None:
        return _EXTRA_ORDER[2], names
    local_names = {
        base_name(document["symbols"][usr]["name"])
        for usr in list(data["references"]) + list(data["definitions"])
        if usr in document["symbols"]
    }
    if any(name in local_names for name in names):
        return _EXTRA_ORDER[0], names
    if any(name in set(data["external_reference_names"]) for name in names):
        return _EXTRA_ORDER[1], names
    return _EXTRA_ORDER[2], names


def compare(document: Mapping[str, object], root: Path, top: int = 40, examples: int = 5) -> Dict[str, object]:
    sources = mm.SourceSet(root, Path(str(document.get("source_dir", mm.APP_SOURCE_DIR))))
    regex_index = mm.declaration_index(sources)
    regex_edges = mm.file_edges(sources, regex_index)
    index_edges_full = file_edges(document)
    index_edges = {source: set(targets) for source, targets in index_edges_full.items()}

    regex_pairs = wrong_way_pairs(regex_edges)
    index_pairs = wrong_way_pairs(index_edges)
    regex_targets = collections.Counter(t for _, t in regex_pairs)
    index_targets = collections.Counter(t for _, t in index_pairs)
    regex_top = [entry["file"] for entry in ranked(regex_targets, top)]
    index_top = [entry["file"] for entry in ranked(index_targets, top)]

    regex_scc = max(mm.strongly_connected_components(component_graph(regex_edges)), key=len, default=[])
    index_scc = max(mm.strongly_connected_components(component_graph(index_edges)), key=len, default=[])

    missed: Dict[str, List[Tuple[str, str]]] = collections.defaultdict(list)
    for source, target in sorted(index_pairs - regex_pairs):
        category = classify_index_only(document, regex_index, source, target, index_edges_full[source][target])
        missed[category].append((source, target))
    extra: Dict[str, List[Dict[str, object]]] = collections.defaultdict(list)
    for source, target in sorted(regex_pairs - index_pairs):
        category, names = classify_regex_only(document, regex_index, sources.stripped.get(source, ""), source, target)
        extra[category].append({"source": source, "target": target, "names": names})

    def missed_examples(pairs: List[Tuple[str, str]]) -> List[Dict[str, object]]:
        return [
            {
                "source": source,
                "target": target,
                "symbols": [symbol_label(document, usr) for usr in sorted(index_edges_full[source][target])[:4]],
            }
            for source, target in pairs[:examples]
        ]

    def target_row(name: str) -> Dict[str, object]:
        return {
            "file": name,
            "regex_edges": regex_targets.get(name, 0),
            "index_edges": index_targets.get(name, 0),
            "regex_rank": regex_top.index(name) + 1 if name in regex_top else None,
            "index_rank": index_top.index(name) + 1 if name in index_top else None,
        }

    return {
        "wrong_way_file_edges": {
            "regex": len(regex_pairs),
            "index": len(index_pairs),
            "both": len(regex_pairs & index_pairs),
            "regex_only": len(regex_pairs - index_pairs),
            "index_only": len(index_pairs - regex_pairs),
        },
        "file_edges": {
            "regex": sum(len(t) for t in regex_edges.values()),
            "index": sum(len(t) for t in index_edges.values()),
        },
        "top_targets": {
            "overlap": len(set(regex_top) & set(index_top)),
            "compared": top,
            "rows": [target_row(name) for name in index_top],
            "regex_only": [target_row(name) for name in regex_top if name not in index_top],
        },
        "largest_cycle": {
            "regex": len(regex_scc),
            "index": len(index_scc),
            "regex_only_components": sorted(set(regex_scc) - set(index_scc)),
            "index_only_components": sorted(set(index_scc) - set(regex_scc)),
        },
        "index_only_wrong_way_edges": {
            category: {"count": len(missed[category]), "examples": missed_examples(missed[category])}
            for category in _MISSED_ORDER
            if missed.get(category)
        },
        "regex_only_wrong_way_edges": {
            category: {"count": len(extra[category]), "examples": extra[category][:examples]}
            for category in _EXTRA_ORDER
            if extra.get(category)
        },
    }


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------


def load_document(args: argparse.Namespace, root: Path) -> Dict[str, object]:
    if args.graph:
        document = json.loads(Path(args.graph).read_text(encoding="utf-8"))
        if document.get("version") != GRAPH_VERSION:
            raise SystemExit(f"{args.graph}: unsupported graph version {document.get('version')}")
        refresh_cached_freshness(document, root)
        return document
    store_path = Path(args.store) if args.store else default_store_path(root)
    if store_path is None or not store_path.is_dir():
        raise SystemExit(
            "no index store found; build first (./conductor swift-build --product RepoPrompt) or pass --store"
        )
    library = Path(args.library) if args.library else default_library_path()
    if library is None or not library.is_file():
        raise SystemExit("libIndexStore.dylib not found; pass --library or set REPOPROMPT_LIBINDEXSTORE")
    store = IndexStore(store_path, library)
    try:
        return extract_graph(store, root)
    finally:
        store.close()


def refresh_cached_freshness(document: Dict[str, object], root: Path) -> None:
    """Revalidate a saved graph against current source bytes, or mark it unknown."""
    freshness = document.get("freshness")
    if not isinstance(freshness, dict):
        freshness = {}
        document["freshness"] = freshness
    expected = freshness.get("source_sha256")
    if not isinstance(expected, dict):
        freshness["current"] = False
        freshness["freshness_unknown"] = True
        return
    source_dir = Path(str(document.get("source_dir", mm.APP_SOURCE_DIR)))
    actual = {
        path.relative_to(root / source_dir).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in mm.swift_files(root / source_dir)
    }
    freshness["unindexed_files"] = sorted(set(actual) - set(document.get("files", {})))
    freshness["stale_files"] = sorted(
        rel for rel, digest in actual.items() if rel in document.get("files", {}) and expected.get(rel) != digest
    )
    freshness["current"] = not freshness["unindexed_files"] and not freshness["stale_files"] and not (set(expected) - set(actual))


def warn_if_stale(document: Mapping[str, object]) -> None:
    freshness = document.get("freshness", {})
    stale = len(freshness.get("stale_files", []))  # type: ignore[union-attr]
    unindexed = len(freshness.get("unindexed_files", []))  # type: ignore[union-attr]
    if stale or unindexed or freshness.get("current") is False:
        print(
            f"warning: index is not current ({stale} stale, {unindexed} unindexed source files); rebuild for exact results",
            file=sys.stderr,
        )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("dump", "report", "readiness", "compare", "edge", "check"))
    parser.add_argument("paths", nargs="*", help="edge: SOURCE TARGET")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--store", help="index store directory (default .build/out or .build/*/debug/index/store)")
    parser.add_argument("--library", help="libIndexStore.dylib (default: next to `xcrun --find swift`)")
    parser.add_argument("--graph", help="read a graph document written by `dump` instead of the store")
    parser.add_argument("--output", help="dump: file to write")
    parser.add_argument("--baseline", type=Path, default=Path("docs/migrations/build-modularization/build-ratchets.json"))
    parser.add_argument("--files", nargs="+", default=[], help="readiness: candidate files or directories")
    parser.add_argument("--top", type=int, default=40)
    # Intermixed parsing lets `edge` paths follow options on Python 3.9 as well as newer versions.
    args = parser.parse_intermixed_args(argv)
    root = args.root.resolve()

    if args.command == "dump" and not args.output:
        parser.error("dump requires --output")
    if args.command == "readiness" and not args.files:
        parser.error("readiness requires --files")
    if args.command == "edge" and len(args.paths) != 2:
        parser.error("edge requires SOURCE TARGET")

    document = load_document(args, root)
    warn_if_stale(document)
    if args.command == "check":
        freshness = document.get("freshness", {})
        if freshness.get("current") is not True:
            print("index ratchet: freshness unproven; rebuild through conductor", file=sys.stderr)
            return 1
        limits = json.loads((root / args.baseline).read_text(encoding="utf-8"))["index"]
        metrics = analyze(document)["metrics"]
        checks = (
            ("index_wrong_way_file_edges", "wrong_way_file_edges"),
            ("index_largest_cycle_components", "largest_cycle_components"),
        )
        failures = [f"{metric} {metrics[metric]} > {limits[limit]}" for metric, limit in checks
                    if metrics[metric] > limits[limit]]
        for error in failures:
            print(f"index ratchet: {error}", file=sys.stderr)
        if failures:
            return 1
        print("index ratchet: " + "; ".join(f"{metric} {metrics[metric]}/{limits[limit]}"
                                               for metric, limit in checks))
        if args.output:
            output = root / args.output
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps({"source_sha256": freshness["source_sha256"],
                                          "metrics": {metric: metrics[metric] for metric, _ in checks}},
                                         sort_keys=True) + "\n", encoding="utf-8")
        return 0

    if args.command == "dump":
        Path(args.output).write_text(json.dumps(document, sort_keys=True) + "\n", encoding="utf-8")
        print(f"wrote {args.output} ({len(document['files'])} files, {len(document['symbols'])} symbols)")
        return 0
    if args.command == "report":
        result: Dict[str, object] = analyze(document, args.top)
    elif args.command == "readiness":
        result = readiness(document, args.files)
    elif args.command == "compare":
        result = compare(document, root, args.top)
    else:
        result = edge_detail(document, args.paths[0], args.paths[1])
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
