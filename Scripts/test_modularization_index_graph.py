#!/usr/bin/env python3
"""Unit tests for the index-store dependency graph (synthetic fixtures; no build required)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import modularization_index_graph as ig  # noqa: E402

APP = "Sources/RepoPrompt"
DEF = ig.ROLE_DEFINITION
REF = ig.ROLE_REFERENCE
IMPLICIT = ig.ROLE_IMPLICIT

# Layers (triage ranks): Infrastructure/Utilities 0, Infrastructure/UI 1, App 12.
UTIL = "Infrastructure/Utilities/Helper.swift"
UI = "Infrastructure/UI/Theme.swift"
FONT = "App/FontPreset.swift"
SHELL = "App/Shell.swift"

SOURCES = {
    # Utilities wrongly reaches up to App through members only; the regex indexes top-level names.
    UTIL: "struct HelperThing {\n    func size() -> Int { Theme.current.points }\n}\n",
    # UI wrongly names the App type, but it is indented under #if, so the regex cannot see it.
    # Its local `compare` shadows Shell's global, so the regex invents UI -> Shell.
    UI: "struct ThemeValue {\n    let preset = FontPresetValue.small\n"
        "    func check() -> Int { let compare = 1; return compare }\n}\n",
    FONT: "#if canImport(Foundation)\n    enum FontPresetValue {\n        case small\n        var points: Int { 12 }\n    }\n#endif\n"
          "let helperUse = HelperThing()\n",
    SHELL: "struct ShellView {\n    func body() { _ = ThemeValue() }\n}\n"
           "func compare(_ a: Int, _ b: Int) -> Bool { a < b }\n",
}

USR = {
    "helper": "s:13RepoPromptApp11HelperThingV",
    "size": "s:13RepoPromptApp11HelperThingV4sizeSiyF",
    "theme": "s:13RepoPromptApp10ThemeValueV",
    "preset": "s:13RepoPromptApp15FontPresetValueO",
    "small": "s:13RepoPromptApp15FontPresetValueO5smallyA2CmF",
    "points": "s:13RepoPromptApp15FontPresetValueO6pointsSivp",
    "points_get": "s:13RepoPromptApp15FontPresetValueO6pointsSivg",
    "compare": "s:13RepoPromptApp7compareySbSi_SitF",
    "shell": "s:13RepoPromptApp9ShellViewV",
    "int": "s:Si",
    "uuid": "s:10Foundation4UUIDV",
}


def occ(roles: int, key: str, name: str, kind: str) -> ig.Occurrence:
    return ig.Occurrence(roles=roles, usr=USR[key], name=name, kind=kind)


RECORDS = {
    "util-new": [
        occ(DEF, "helper", "HelperThing", "struct"),
        occ(DEF, "size", "size()", "instance-method"),
        occ(REF, "small", "small", "enum-case"),
        occ(REF, "points", "points", "instance-property"),
        occ(REF, "points_get", "getter:points", "instance-method"),
        occ(REF, "int", "Int", "struct"),
    ],
    "util-old": [occ(DEF, "helper", "HelperThing", "struct")],
    "ui": [
        occ(DEF, "theme", "ThemeValue", "struct"),
        occ(REF, "preset", "FontPresetValue", "enum"),
        occ(REF | IMPLICIT, "small", "small", "enum-case"),
    ],
    "font": [
        occ(DEF, "preset", "FontPresetValue", "enum"),
        occ(DEF, "small", "small", "enum-case"),
        occ(DEF, "points", "points", "instance-property"),
        occ(DEF, "points_get", "getter:points", "instance-method"),
        occ(REF, "helper", "HelperThing", "struct"),
        occ(REF, "uuid", "UUID", "struct"),
    ],
    "shell": [
        occ(DEF, "shell", "ShellView", "struct"),
        occ(DEF, "compare", "compare(_:_:)", "function"),
        occ(REF, "theme", "ThemeValue", "struct"),
    ],
    "other-module": [occ(DEF, "theme", "ThemeValue", "struct")],
}


class FakeStore:
    def __init__(self, root: Path, units):
        self.root = root
        self._units = units

    def units(self):
        return iter(self._units)

    def occurrences(self, record):
        return RECORDS[record]


def write_sources(root: Path) -> None:
    for rel, text in SOURCES.items():
        path = root / APP / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        os.utime(path, (1_000, 1_000))


def unit(root: Path, rel: str, record: str, mtime: float = 2_000.0, module: str = "RepoPromptApp", imports=()):
    return ig.Unit(
        main_file=str(root / APP / rel), module=module, mtime=mtime, records=(record,), imports=tuple(imports)
    )


def fixture_units(root: Path):
    return [
        unit(root, UTIL, "util-old", mtime=1_500.0),
        unit(root, UTIL, "util-new", mtime=2_500.0, imports=("RepoPromptApp", "RepoPromptShared")),
        unit(root, UI, "ui"),
        unit(root, FONT, "font"),
        unit(root, SHELL, "shell"),
        unit(root, UI, "other-module", module="RepoPromptTests"),
        unit(root, "App/Deleted.swift", "shell"),
        ig.Unit(main_file=str(root / "Sources/Other/X.swift"), module="RepoPromptApp", mtime=1.0, records=("shell",), imports=()),
        # A seeded .build carries newer units for another checkout's copy of the same file.
        ig.Unit(
            main_file=f"/other-checkout/{APP}/{UTIL}", module="RepoPromptApp", mtime=9_999.0, records=("util-old",), imports=()
        ),
    ]


class ExtractionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        write_sources(self.root)
        self.document = ig.extract_graph(FakeStore(self.root, fixture_units(self.root)), self.root, built_source_sha256=ig.source_hashes(self.root))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_newest_unit_wins_and_foreign_units_are_ignored(self) -> None:
        files = self.document["files"]
        self.assertEqual(sorted(files), sorted(SOURCES))
        self.assertIn(USR["size"], files[UTIL]["definitions"])  # from util-new, not util-old
        self.assertEqual(files[UTIL]["imports"], ["RepoPromptShared"])
        self.assertEqual(self.document["freshness"]["index_units_for_deleted_files"], 1)

    def test_references_keep_only_module_definitions(self) -> None:
        util = self.document["files"][UTIL]
        self.assertEqual(set(util["references"]), {USR["small"], USR["points"], USR["points_get"]})
        self.assertEqual(self.document["files"][FONT]["external_reference_names"], ["UUID"])
        self.assertNotIn(USR["int"], self.document["symbols"])
        self.assertEqual(self.document["symbols"][USR["compare"]]["kind"], "function")

    def test_implicit_only_references_are_marked(self) -> None:
        self.assertEqual(self.document["files"][UI]["implicit_only"], [USR["small"]])

    def test_freshness_reports_stale_and_unindexed_files(self) -> None:
        (self.root / APP / "App/New.swift").write_text("struct NewThing {}\n", encoding="utf-8")
        before = self.document["freshness"]["source_sha256"]
        (self.root / APP / SHELL).write_text(SOURCES[SHELL] + "// modified\n", encoding="utf-8")
        document = ig.extract_graph(FakeStore(self.root, fixture_units(self.root)), self.root, built_source_sha256=before)
        self.assertEqual(document["freshness"]["unindexed_files"], ["App/New.swift"])
        self.assertEqual(document["freshness"]["stale_files"], [SHELL])
        readiness = ig.readiness(document, ["App", "Infrastructure"])
        self.assertFalse(readiness["ready"])
        self.assertFalse(readiness["coverage_complete"])

    def test_mtime_only_change_does_not_stale_content_hash(self) -> None:
        os.utime(self.root / APP / UTIL, (9_999, 9_999))
        ig.refresh_cached_freshness(self.document, self.root)
        self.assertTrue(self.document["freshness"]["current"])

    def test_missing_build_fingerprint_is_unknown(self) -> None:
        document = ig.extract_graph(FakeStore(self.root, fixture_units(self.root)), self.root,
                                    built_source_sha256=None)
        self.assertFalse(document["freshness"]["current"])
        self.assertTrue(document["freshness"]["freshness_unknown"])

    def test_saved_graph_revalidates_source_edit(self) -> None:
        self.assertTrue(ig.readiness(self.document, ["App", "Infrastructure"])["ready"])
        (self.root / APP / UTIL).write_text(SOURCES[UTIL] + "\n// edited after dump\n")
        ig.refresh_cached_freshness(self.document, self.root)
        result = ig.readiness(self.document, ["App", "Infrastructure"])
        self.assertFalse(result["ready"])
        self.assertIn(UTIL, result["freshness"]["stale_files"])

    def test_legacy_graph_without_fingerprint_cannot_claim_ready(self) -> None:
        self.document["freshness"].pop("source_sha256")
        ig.refresh_cached_freshness(self.document, self.root)
        self.assertFalse(ig.readiness(self.document, ["App", "Infrastructure"])["ready"])


class AnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(os.path.realpath(cls.tmp.name))
        write_sources(cls.root)
        cls.document = ig.extract_graph(FakeStore(cls.root, fixture_units(cls.root)), cls.root, built_source_sha256=ig.source_hashes(cls.root))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def test_file_edges_follow_definitions(self) -> None:
        edges = ig.file_edges(self.document)
        self.assertEqual(set(edges[UTIL]), {FONT})
        self.assertEqual(edges[UTIL][FONT][USR["points"]], 1)
        self.assertEqual(set(edges[FONT]), {UTIL})
        self.assertEqual(set(edges[SHELL]), {UI})

    def test_report_counts_wrong_way_edges_and_cycles(self) -> None:
        result = ig.analyze(self.document)
        metrics = result["metrics"]
        # Utilities -> App and UI -> App point upward; App -> anything lower does not.
        self.assertEqual(metrics["index_wrong_way_file_edges"], 2)
        self.assertEqual(result["top_wrong_way_targets"], [{"file": FONT, "edges": 2}])
        self.assertEqual(result["largest_cycle"], ["App", "Infrastructure/UI", "Infrastructure/Utilities"])
        self.assertEqual(metrics["index_largest_cycle_components"], 3)
        self.assertEqual(metrics["index_largest_file_cycle"], 2)  # Helper <-> FontPreset
        self.assertEqual(metrics["index_implicit_only_file_edges"], 0)

    def test_readiness_lists_blockers_and_inbound_access(self) -> None:
        result = ig.readiness(self.document, ["Sources/RepoPrompt/Infrastructure/Utilities", "Infrastructure/UI/"])
        self.assertEqual(result["files"], 2)
        self.assertFalse(result["ready"])
        self.assertEqual(result["outbound_target_files"], 1)
        self.assertEqual(result["outbound_file_edges"], 2)
        blocker = result["blockers"][0]
        self.assertEqual((blocker["target"], blocker["from_files"]), (FONT, 2))
        # The getter folds into its property; it is not a separate symbol to expose.
        self.assertEqual(
            set(blocker["symbols"]), {"FontPresetValue [enum]", "small [enum-case]", "points [instance-property]"}
        )
        self.assertEqual(result["outbound_symbols"], 3)
        self.assertEqual(result["module_imports"], ["RepoPromptShared"])
        self.assertEqual(result["inbound_files"], 2)  # FontPreset and Shell use the set
        self.assertEqual(result["unmatched_paths"], [])

    def test_readiness_ready_set_and_unmatched_paths(self) -> None:
        result = ig.readiness(self.document, ["App", "Infrastructure"])
        self.assertTrue(result["ready"])
        self.assertEqual(result["outbound_file_edges"], 0)
        missing = ig.readiness(self.document, ["Features/Nope"])
        self.assertFalse(missing["ready"])
        self.assertEqual(missing["unmatched_paths"], ["Features/Nope"])

    def test_edge_detail_lists_symbols(self) -> None:
        detail = ig.edge_detail(self.document, UTIL, FONT)
        self.assertTrue(detail["wrong_way"])
        self.assertEqual(
            {entry["symbol"] for entry in detail["symbols"]},
            {"small [enum-case]", "points [instance-property]", "getter:points [instance-method]"},
        )
        ui = ig.edge_detail(self.document, UI, FONT)
        self.assertEqual({e["symbol"]: e["implicit_only"] for e in ui["symbols"]}["small [enum-case]"], True)

    def test_compare_explains_disagreements(self) -> None:
        result = ig.compare(self.document, self.root)
        counts = result["wrong_way_file_edges"]
        self.assertEqual((counts["regex"], counts["index"], counts["both"]), (1, 2, 0))
        missed = result["index_only_wrong_way_edges"]
        self.assertEqual(missed[ig._MISSED_ORDER[2]]["examples"][0]["source"], UI)  # #if-indented type
        self.assertEqual(missed[ig._MISSED_ORDER[3]]["examples"][0]["source"], UTIL)  # members only
        extra = result["regex_only_wrong_way_edges"]
        self.assertEqual(list(extra), [ig._EXTRA_ORDER[2]])
        self.assertEqual(extra[ig._EXTRA_ORDER[2]]["examples"][0], {"source": UI, "target": SHELL, "names": ["compare"]})
        self.assertEqual((result["largest_cycle"]["regex"], result["largest_cycle"]["index"]), (2, 3))
        self.assertEqual(result["largest_cycle"]["index_only_components"], ["Infrastructure/Utilities"])
        self.assertEqual(result["top_targets"]["rows"][0]["file"], FONT)
        self.assertEqual(result["top_targets"]["regex_only"][0]["file"], SHELL)

    def test_classifiers(self) -> None:
        regex_index = {"FontPresetValue": {FONT}, "compare": {SHELL}}
        self.assertEqual(
            ig.classify_index_only(self.document, regex_index, UTIL, FONT, [USR["points"]]), ig._MISSED_ORDER[3]
        )
        self.assertEqual(
            ig.classify_index_only(self.document, regex_index, UTIL, FONT, [USR["points"], USR["preset"]]),
            ig._MISSED_ORDER[0],
        )
        ambiguous = {"FontPresetValue": {"a", "b", FONT}}
        self.assertEqual(
            ig.classify_index_only(self.document, ambiguous, UI, FONT, [USR["preset"]]), ig._MISSED_ORDER[1]
        )
        self.assertEqual(
            ig.classify_index_only(self.document, {}, UTIL, FONT, [USR["preset"]]), ig._MISSED_ORDER[2]
        )
        category, names = ig.classify_regex_only(self.document, regex_index, "let compare = 1", UI, SHELL)
        self.assertEqual((category, names), (ig._EXTRA_ORDER[2], ["compare"]))
        category, _ = ig.classify_regex_only(self.document, {"UUID": {UTIL}}, "UUID()", FONT, UTIL)
        self.assertEqual(category, ig._EXTRA_ORDER[1])
        category, _ = ig.classify_regex_only(self.document, {"ThemeValue": {FONT}}, "ThemeValue()", SHELL, FONT)
        self.assertEqual(category, ig._EXTRA_ORDER[0])

    def test_base_name_strips_accessors_and_signatures(self) -> None:
        self.assertEqual(ig.base_name("getter:rootID"), "rootID")
        self.assertEqual(ig.base_name("compare(_:_:)"), "compare")
        self.assertEqual(ig.base_name("init(rootID:)"), "init")


class CommandLineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        write_sources(self.root)
        document = ig.extract_graph(FakeStore(self.root, fixture_units(self.root)), self.root, built_source_sha256=ig.source_hashes(self.root))
        self.graph = self.root / "graph.json"
        self.graph.write_text(json.dumps(document), encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_main(self, *argv: str):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ig.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_report_readiness_and_edge_from_graph_file(self) -> None:
        common = ("--root", str(self.root), "--graph", str(self.graph))
        code, out, _ = self.run_main("report", *common)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["metrics"]["index_wrong_way_file_edges"], 2)
        code, out, _ = self.run_main("readiness", *common, "--files", "Infrastructure/Utilities")
        self.assertEqual(json.loads(out)["blockers"][0]["target"], FONT)
        code, out, _ = self.run_main("edge", *common, UTIL, FONT)
        self.assertTrue(json.loads(out)["wrong_way"])

    def test_swiftbuild_index_store_location_and_check_attestation(self) -> None:
        units = self.root / '.build/out/v5/units'
        units.mkdir(parents=True)
        self.assertEqual(ig.default_store_path(self.root), self.root / '.build/out')
        baseline = self.root / 'ratchets.json'
        baseline.write_text(json.dumps({'index': {'wrong_way_file_edges': 100,
                                                   'largest_cycle_components': 100}}))
        attestation = self.root / '.build/modularization/index-check.json'
        code, _, _ = self.run_main('check', '--root', str(self.root), '--graph', str(self.graph),
                                   '--baseline', str(baseline), '--output', str(attestation))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(attestation.read_text())['source_sha256'], ig.source_hashes(self.root))

    def test_missing_store_and_bad_arguments_fail_clearly(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.run_main("report", "--root", str(self.root))
        self.assertIn("no index store found", str(raised.exception))
        with self.assertRaises(SystemExit):
            self.run_main("readiness", "--root", str(self.root), "--graph", str(self.graph))
        with self.assertRaises(SystemExit):
            self.run_main("dump", "--root", str(self.root), "--graph", str(self.graph))

    def test_stale_index_warns(self) -> None:
        document = json.loads(self.graph.read_text(encoding="utf-8"))
        (self.root / APP / SHELL).write_text(SOURCES[SHELL] + "// modified\n", encoding="utf-8")
        _, _, err = self.run_main("report", "--root", str(self.root), "--graph", str(self.graph))
        self.assertIn("1 stale", err)


@unittest.skipUnless(ig.default_library_path(), "libIndexStore.dylib not available")
class LibraryBindingTests(unittest.TestCase):
    def test_empty_store_has_no_units(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = ig.IndexStore(Path(tmp), ig.default_library_path())
            try:
                self.assertEqual(list(store.units()), [])
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
