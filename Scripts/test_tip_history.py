#!/usr/bin/env python3
"""Offline contracts for Tip history; never publishes or uses signing secrets."""
import base64
import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.dont_write_bytecode = True
import tip_history as history

REPOSITORY = "repoprompt/repoprompt-ce-tip-updates"
SIGNATURE = base64.b64encode(bytes(64)).decode()


def entry(number, seed=False):
    return {"tag": f"tip-{number:012x}", "buildNumber": str(number), "historyCatalogSha256": None, "origin": "seed" if seed else "catalog", "title": f"Build {number}", "downgradeBarrier": False, "downgradeBarrierReasons": []}


def envelope(page):
    # A syntactically valid dummy signature. These pure chain tests do NOT
    # authenticate it; shell/client verifier tests must cover cryptography.
    return history.wrap(history.canonical(page), SIGNATURE)


class TipHistoryChainTests(unittest.TestCase):
    def test_bootstrap_and_seed_tail_after_1_29_30_60_publishes(self):
        page = history.assemble_page(entry(100), REPOSITORY, None, [entry(i, True) for i in range(99, 70, -1)])
        catalogs = {page["generatedForTag"]: envelope(page)}
        for offset in range(61):
            if offset:
                page = history.assemble_page(entry(100 + offset), REPOSITORY, catalogs[f"tip-{99 + offset:012x}"])
                catalogs[page["generatedForTag"]] = envelope(page)
            if offset not in (0, 1, 29, 30, 60):
                continue
            self.assertEqual(len(page["entries"]), 30)
            loaded = page["entries"]
            reference = page["olderPage"]
            visited = set()
            while reference:
                self.assertNotIn(reference["tag"], visited)
                visited.add(reference["tag"])
                data = catalogs[reference["tag"]]
                self.assertEqual(hashlib.sha256(data).hexdigest(), reference["sha256"])
                older = history.page_from_envelope(data)
                loaded = history.merge_pages(loaded, older["entries"])
                reference = older["olderPage"]
            self.assertEqual([e["buildNumber"] for e in loaded], [str(i) for i in range(100 + offset, 70, -1)])

    def test_ordinary_chain_and_exact_parent_fence(self):
        parent = history.assemble_page(entry(1), REPOSITORY, None)
        raw = envelope(parent)
        child = history.assemble_page(entry(2), REPOSITORY, raw)
        history.validate_live_parent(child, raw)
        changed = copy.deepcopy(parent)
        changed["entries"][0]["title"] = "Changed parent bytes"
        with self.assertRaisesRegex(history.HistoryError, "superseded"):
            history.validate_live_parent(child, envelope(changed))

    def test_overlap_requires_notes_and_barriers_match(self):
        for field, value in (("title", "Changed"), ("downgradeBarrier", True), ("downgradeBarrierReasons", ["Unsafe"])):
            a = entry(2)
            b = copy.deepcopy(a)
            b[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(history.HistoryError, "integrity"):
                history.merge_pages([a], [b, entry(1)])

    def test_overlap_allows_only_digest_enrichment(self):
        a = entry(2)
        b = copy.deepcopy(a)
        b["historyCatalogSha256"] = "a" * 64
        self.assertEqual(len(history.merge_pages([b], [a, entry(1)])), 2)
        with self.assertRaises(history.HistoryError):
            history.merge_pages([a], [b])
        a["historyCatalogSha256"] = "b" * 64
        with self.assertRaises(history.HistoryError):
            history.merge_pages([a], [b])

    def test_bad_pages_fail_closed(self):
        original = history.assemble_page(entry(3), REPOSITORY, None, [entry(2)])
        changes = [
            ("entries", []), ("entries", [entry(3), entry(3)]),
            ("entries", [entry(2), entry(3)]),
            ("entries", [entry(3)] * 31),
            ("generatedForTag", "tip-ffffffffffff"),
            ("schemaVersion", True), ("channel", "stable"),
            ("olderPage", {"tag": "../bad", "sha256": "a" * 64}),
        ]
        for key, value in changes:
            page = copy.deepcopy(original)
            page[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(history.HistoryError):
                history.validate_page(page)

    def test_envelope_and_domain_separation(self):
        data = b'{"literal":"payload bytes are not recanonicalized"}'
        raw = history.wrap(data, SIGNATURE)
        self.assertEqual(history.extract(raw), (data, bytes(64)))
        self.assertNotEqual(data, history.DOMAIN + data)
        for change in ({"schemaVersion": 2}, {"signature": "?"}, {"payload": "?"}, {"format": "appcast"}):
            malformed = json.loads(raw)
            malformed.update(change)
            with self.assertRaises(history.HistoryError):
                history.extract(history.canonical(malformed))
        with self.assertRaises(history.HistoryError):
            history.extract(b" " * (history.MAX_ENVELOPE + 1))

    def test_cli_preserves_exact_signed_payload_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload.json"
            payload.write_bytes(b'{ "deliberate whitespace": true }\n')
            message = root / "message"
            wrapped = root / "envelope.json"
            extracted = root / "extracted"
            signature = root / "signature"
            script = str(Path(history.__file__).resolve())
            for args in (
                ["signed-message", "--payload", str(payload), "--output", str(message)],
                ["wrap", "--payload", str(payload), "--signature", SIGNATURE, "--output", str(wrapped)],
                ["extract", "--envelope", str(wrapped), "--message-output", str(extracted), "--signature-output", str(signature)],
            ):
                subprocess.run([sys.executable, "-B", script, *args], check=True, capture_output=True)
            self.assertEqual(message.read_bytes(), history.DOMAIN + payload.read_bytes())
            self.assertEqual(extracted.read_bytes(), message.read_bytes())
            self.assertEqual(signature.read_text().strip(), SIGNATURE)
            result = subprocess.run([sys.executable, "-B", script, "wrap", "--payload", str(payload), "--signature", "bad", "--output", str(wrapped)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("tip-history:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_duplicate_json_keys_are_rejected_even_when_nested(self):
        for raw in (b'{"schemaVersion":1,"schemaVersion":2}', b'{"fragment":{"breaksDowngrade":true,"breaksDowngrade":false}}'):
            with self.subTest(raw=raw), self.assertRaisesRegex(history.HistoryError, "duplicate"):
                history.parse_json(raw)
        raw = history.wrap(b'{}', SIGNATURE)
        raw = raw.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1')
        with self.assertRaisesRegex(history.HistoryError, "duplicate"):
            history.extract(raw)

    def test_no_live_cannot_silently_reset_history(self):
        page = history.assemble_page(entry(1), REPOSITORY, None)
        with self.assertRaisesRegex(history.HistoryError, "audited bootstrap not implemented"):
            history.validate_live_parent(page, None)


class TipHistoryNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        self.root = self.commit("Initial")

    def git(self, *args):
        return history.git(self.repo, *args).strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def fragment(self, name, **updates):
        path = self.repo / "ReleaseNotes/Tip" / (name + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        value = {"schemaVersion": 1, "title": name, "notes": ["A reviewed note"]}
        value.update(updates)
        path.write_text(json.dumps(value))

    def test_merge_title_and_reviewed_notes_order(self):
        self.fragment("First")
        self.commit("First fragment")
        self.fragment("Second", breaksDowngrade=True, breaksDowngradeReason="Changed disk format")
        self.commit("Second fragment")
        head = self.commit("Merge pull request #123 from example/topic\n\nReadable PR title")
        result = history.collect_notes(self.repo, self.root, head)
        self.assertEqual(result["title"], "Second (+1 more)")
        self.assertEqual(result["titleSource"], "reviewed")
        self.assertEqual(result["notes"][-1], {"text": "Readable PR title", "source": "commit"})
        self.assertEqual(result["downgradeBarrierReasons"], ["Changed disk format"])
        self.assertEqual(result["commitRange"], {"fromCommit": self.root, "count": 3})

    def test_real_merge_does_not_repeat_already_published_fragments(self):
        main_branch = self.git("branch", "--show-current")
        self.git("checkout", "-q", "-b", "topic")
        self.fragment("Topic change")
        self.commit("Topic fragment")
        self.git("checkout", "-q", main_branch)
        self.fragment("Already released", breaksDowngrade=True, breaksDowngradeReason="Old barrier")
        previous = self.commit("Previously published fragment")
        self.git("merge", "--no-ff", "-m", "Merge pull request #123 from example/topic\n\nNew topic feature", "topic")
        candidate = self.git("rev-parse", "HEAD")
        result = history.collect_notes(self.repo, previous, candidate)
        self.assertEqual(result["title"], "Topic change")
        self.assertEqual(result["notes"], [{"text": "Topic change", "source": "reviewed"}, {"text": "A reviewed note", "source": "reviewed"}])
        self.assertFalse(result["downgradeBarrier"])
        self.assertEqual(result["commitRange"]["count"], 1)

    def test_bootstrap_and_nonancestor_are_blocking_not_safe_fallbacks(self):
        head = self.commit("Candidate")
        result = history.collect_notes(self.repo, None, head)
        self.assertTrue(result["downgradeBarrier"])
        self.assertEqual(result["downgradeBarrierReasons"], [history.DISCONTINUITY])
        self.git("checkout", "-q", "-b", "other", self.root)
        other = self.commit("Other branch")
        self.assertTrue(history.collect_notes(self.repo, other, head)["downgradeBarrier"])

    def test_barriers_are_not_truncated_by_display_notes(self):
        self.fragment("Barrier", breaksDowngrade=True, breaksDowngradeReason="Unsafe")
        self.commit("Barrier fragment")
        for i in range(12):
            head = self.commit(f"Fix {i}")
        result = history.collect_notes(self.repo, self.root, head)
        self.assertEqual(len(result["notes"]), 10)
        self.assertGreater(result["omittedCount"], 0)
        self.assertTrue(result["downgradeBarrier"])

    def test_500_commit_display_fallback_still_scans_all_safety_fragments(self):
        commits = [f"{number:040x}" for number in range(1, 503)]
        barrier = {"schemaVersion": 1, "title": "Early format change", "notes": [], "breaksDowngrade": True, "breaksDowngradeReason": "Unsafe disk format"}
        scanned = []

        def fake_git(repo, *args):
            if args[0] == "rev-list":
                return "\n".join(commits)
            if args[0] == "diff-tree":
                commit = args[args.index("-r") + 1]
                scanned.append(commit)
                return "ReleaseNotes/Tip/barrier.json\0" if commit == commits[0] else ""
            if args[0] == "show" and ":ReleaseNotes" in args[-1]:
                return json.dumps(barrier)
            if "--format=%B" in args:
                return "Final candidate title"
            if "--format=%cI" in args:
                return "2026-10-22T00:00:00Z"
            return ""

        with patch.object(history, "git", side_effect=fake_git), patch.object(history, "is_ancestor", return_value=True):
            result = history.collect_notes(self.repo, "f" * 40, commits[-1])
        self.assertEqual(scanned, commits)
        self.assertEqual(result["title"], "Final candidate title")
        self.assertEqual(result["notes"], [{"text": "Final candidate title", "source": "commit"}])
        self.assertEqual(result["downgradeBarrierReasons"], ["Unsafe disk format"])
        self.assertEqual(result["commitRange"]["count"], 502)

    def test_bad_fragment_fails_even_when_notes_are_full(self):
        for i in range(11):
            self.commit(f"Fix {i}")
        self.fragment("Invalid", breaksDowngrade=True)
        head = self.commit("Bad fragment")
        with self.assertRaises(history.HistoryError):
            history.collect_notes(self.repo, self.root, head)

    def test_only_added_fragments_and_readme_are_allowed(self):
        self.fragment("Original")
        head = self.commit("New fragment")
        self.fragment("Original", title="Edited, not newly added")
        final = self.commit("An edit")
        result = history.collect_notes(self.repo, head, final)
        self.assertEqual(result["titleSource"], "commit")
        (self.repo / "ReleaseNotes/Tip/README.md").write_text("Instructions")
        history.lint_fragments(self.repo)
        (self.repo / "ReleaseNotes/Tip/stray.txt").write_text("bad")
        with self.assertRaises(history.HistoryError):
            history.lint_fragments(self.repo)

    def test_fragment_types_lengths_and_sanitization(self):
        fragment = {"schemaVersion": 1, "title": "Hello", "notes": []}
        for change in ({"schemaVersion": True}, {"title": "x" * 91}, {"notes": ["x"] * 4}, {"breaksDowngrade": "false"}, {"extra": "bad"}, {"breaksDowngrade": True}):
            with self.subTest(change=change), self.assertRaises(history.HistoryError):
                history.validate_fragment({**fragment, **change})
        self.assertEqual(history.clean("e\u0301 \u202eevil\u2069\x00  title"), "é evil title")
        self.assertEqual(history.clean("e\u202e\u0301"), "é")

    def test_unicode_truncation_preserves_extended_graphemes(self):
        text = "👩‍👩‍👧‍👦" * 3 + "suffix"
        self.assertEqual(history.truncate_many([text], 2), ["👩‍👩‍👧‍👦" * 2])


if __name__ == "__main__":
    unittest.main()
