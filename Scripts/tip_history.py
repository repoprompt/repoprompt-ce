#!/usr/bin/env python3
"""Deterministic Tip history contracts. Signing and publication remain in shell.

This module deliberately has no GitHub mutation or signing-key access. Envelope
extraction is NOT authentication: callers must verify the extracted signed
message with the pinned Sparkle public key before trusting a parent catalog.
This foundational module is not a production admission or per-entry validator;
its pure page assembly helpers require independently audited entry metadata.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import copy
import ctypes
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

sys.dont_write_bytecode = True
from stable_rollout import RolloutError, parse_build

FORMAT = "repoprompt-tip-history"
DOMAIN = b"repoprompt-tip-history-v1\n"
WINDOW = 30
MAX_ENVELOPE = 1024 * 1024
TAG = re.compile(r"tip-[0-9a-f]{12}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
DISCONTINUITY = "Release history discontinuity; downgrade safety unknown"
FRAGMENT_KEYS = {"schemaVersion", "title", "notes", "breaksDowngrade", "breaksDowngradeReason"}


class HistoryError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise HistoryError(message)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def parse_json(data: bytes | str) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    def invalid_constant(value):
        raise HistoryError(f"non-JSON numeric constant: {value}")
    value = json.loads(data, object_pairs_hook=unique, parse_constant=invalid_constant)
    require(isinstance(value, dict), "expected JSON object")
    return value


def read_json(path: Path) -> dict:
    return parse_json(path.read_bytes())


def clean(value: str) -> str:
    require(isinstance(value, str), "text must be a string")
    value = unicodedata.normalize("NFC", value)
    value = "".join(c for c in value if not (ord(c) < 32 or 127 <= ord(c) <= 159 or 0x202A <= ord(c) <= 0x202E or 0x2066 <= ord(c) <= 0x2069))
    return unicodedata.normalize("NFC", " ".join(value.split()))


def truncate_many(values: list[str], limit: int) -> list[str]:
    """macOS ICU character boundaries: no code-point/ZWJ truncation or builds.

    The protected signing runner is macOS. Failing to load its system ICU is a
    hard error rather than silently switching to an incompatible text contract.
    ASCII is a fast path and keeps the non-Unicode contracts portable.
    """
    require(limit >= 0, "negative text limit")
    if all(value.isascii() for value in values):
        return [value[:limit] for value in values]
    icu = ctypes.CDLL("/usr/lib/libicucore.A.dylib")
    icu.ubrk_open.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, ctypes.POINTER(ctypes.c_int32)]
    icu.ubrk_open.restype = ctypes.c_void_p
    icu.ubrk_next.argtypes = [ctypes.c_void_p]
    icu.ubrk_next.restype = ctypes.c_int32
    icu.ubrk_close.argtypes = [ctypes.c_void_p]
    icu.ubrk_close.restype = None
    result = []
    for value in values:
        encoded = value.encode("utf-16-le")
        units = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
        status = ctypes.c_int32(0)
        iterator = icu.ubrk_open(0, b"root", units, len(units), ctypes.byref(status))
        require(bool(iterator) and status.value <= 0, "Unicode character segmentation failed")
        try:
            boundary = 0
            for _ in range(limit):
                next_boundary = icu.ubrk_next(iterator)
                if next_boundary == -1:
                    break
                boundary = next_boundary
            result.append(encoded[:boundary * 2].decode("utf-16-le"))
        finally:
            icu.ubrk_close(iterator)
    return result


def validate_fragment(fragment: dict) -> dict:
    require(isinstance(fragment, dict), "fragment must be an object")
    require(set(fragment) <= FRAGMENT_KEYS and {"schemaVersion", "title", "notes"} <= set(fragment), "unexpected or missing fragment fields")
    require(type(fragment["schemaVersion"]) is int and fragment["schemaVersion"] == 1, "unsupported fragment schema")
    title = clean(fragment["title"])
    require(title and truncate_many([title], 90)[0] == title, "fragment title must contain 1...90 graphemes")
    notes = fragment["notes"]
    require(isinstance(notes, list) and len(notes) <= 3, "fragment notes must contain at most three items")
    notes = [clean(note) for note in notes]
    require(all(notes) and truncate_many(notes, 200) == notes, "fragment notes must contain 1...200 graphemes")
    barrier = fragment.get("breaksDowngrade", False)
    require(type(barrier) is bool, "breaksDowngrade must be boolean")
    reason = fragment.get("breaksDowngradeReason")
    if reason is not None:
        reason = clean(reason)
        require(reason and truncate_many([reason], 200)[0] == reason, "barrier reason must contain 1...200 graphemes")
    require(not barrier or reason is not None, "downgrade barrier requires a reason")
    return {"title": title, "notes": notes, "breaksDowngrade": barrier, "breaksDowngradeReason": reason}


def lint_fragments(root: Path) -> None:
    directory = root / "ReleaseNotes/Tip"
    require(directory.is_dir() and not directory.is_symlink() and not directory.parent.is_symlink(), "missing or symlinked ReleaseNotes/Tip directory")
    for path in sorted(directory.iterdir()):
        require(not path.is_symlink() and path.is_file(), f"unexpected fragment path: {path.name}")
        if path.name == "README.md":
            continue
        require(path.suffix == ".json", f"unexpected fragment file: {path.name}")
        validate_fragment(read_json(path))


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True)
    require(result.returncode == 0, f"git {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout


def is_ancestor(repo: Path, older: str, newer: str) -> bool:
    require(bool(COMMIT.fullmatch(older)) and bool(COMMIT.fullmatch(newer)), "commit must be full lowercase SHA")
    result = subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer], capture_output=True)
    require(result.returncode in (0, 1), "cannot prove release ancestry")
    return result.returncode == 0


def subject(repo: Path, commit: str) -> str:
    text = git(repo, "show", "-s", "--format=%B", commit).splitlines()
    first = text[0] if text else ""
    if re.fullmatch(r"Merge pull request #\d+ from .+", first):
        first = next((line for line in text[1:] if line.strip()), first)
    return clean(first)


def collect_notes(repo: Path, previous: str | None, candidate: str) -> dict:
    require(bool(COMMIT.fullmatch(candidate)), "candidate must be full lowercase SHA")
    git(repo, "cat-file", "-e", f"{candidate}^{{commit}}")
    continuity = previous is not None and is_ancestor(repo, previous, candidate)
    commits = git(repo, "rev-list", "--first-parent", "--reverse", f"{previous}..{candidate}").splitlines() if continuity else [candidate]
    # Even when display falls back at 500 commits, every safety fragment in the
    # complete range is validated. Missing objects fail instead of erasing a barrier.
    fragments = {}
    reasons = [] if continuity else [DISCONTINUITY]
    for commit in commits:
        names = git(repo, "diff-tree", "--root", "--diff-merges=first-parent", "--no-commit-id", "--name-only", "-z", "--diff-filter=A", "-r", commit, "--", "ReleaseNotes/Tip/").split("\0")
        parsed = []
        for name in sorted(set(name for name in names if name)):
            if name == "ReleaseNotes/Tip/README.md":
                continue
            require(re.fullmatch(r"ReleaseNotes/Tip/[^/]+\.json", name) is not None, f"unexpected fragment path: {name}")
            blob = parse_json(git(repo, "show", f"{commit}:{name}"))
            fragment = validate_fragment(blob)
            parsed.append(fragment)
            if fragment["breaksDowngrade"] and fragment["breaksDowngradeReason"] not in reasons:
                reasons.append(fragment["breaksDowngradeReason"])
        fragments[commit] = parsed
    display = commits if continuity and len(commits) <= 500 else [candidate]
    reviewed = [fragment for commit in display for fragment in fragments.get(commit, [])]
    title = reviewed[-1]["title"] if reviewed else subject(repo, candidate)
    if reviewed and len(reviewed) > 1:
        title += f" (+{len(reviewed) - 1} more)"
    title = truncate_many([title], 90)[0]
    # The final build-specific fallback is filled by the manifest-bound builder.
    notes = [{"text": text, "source": "reviewed"} for fragment in reviewed for text in [fragment["title"], *fragment["notes"]]]
    messages = [subject(repo, commit) for commit in display if not fragments.get(commit)]
    notes += [{"text": text, "source": "commit"} for text in truncate_many(messages, 200) if text]
    return {"title": title, "titleSource": "reviewed" if reviewed else "commit", "notes": notes[:10], "omittedCount": max(0, len(notes) - 10), "commitRange": {"fromCommit": previous, "count": len(commits) if continuity else 1}, "downgradeBarrier": bool(reasons), "downgradeBarrierReasons": reasons[:3], "releaseCommit": candidate, "commitDate": git(repo, "show", "-s", "--format=%cI", candidate).strip()}


def decode64(value: str, size: int | None = None) -> bytes:
    require(isinstance(value, str), "base64 value must be a string")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise HistoryError("invalid base64") from error
    require(size is None or len(data) == size, "invalid base64 decoded size")
    return data


def extract(envelope_bytes: bytes) -> tuple[bytes, bytes]:
    require(len(envelope_bytes) <= MAX_ENVELOPE, "catalog exceeds 1 MiB")
    envelope = parse_json(envelope_bytes)
    require(isinstance(envelope, dict) and envelope.get("format") == FORMAT and type(envelope.get("schemaVersion")) is int and envelope["schemaVersion"] == 1, "unsupported envelope format")
    return decode64(envelope.get("payload")), decode64(envelope.get("signature"), 64)


def wrap(payload: bytes, signature: str) -> bytes:
    decode64(signature, 64)
    result = canonical({"format": FORMAT, "schemaVersion": 1, "payload": base64.b64encode(payload).decode(), "signature": signature})
    require(len(result) <= MAX_ENVELOPE, "catalog exceeds 1 MiB")
    return result


def validate_reference(reference: object) -> None:
    if reference is None:
        return
    require(isinstance(reference, dict) and set(reference) == {"tag", "sha256"}, "invalid page reference")
    require(isinstance(reference["tag"], str) and TAG.fullmatch(reference["tag"]) is not None and isinstance(reference["sha256"], str) and DIGEST.fullmatch(reference["sha256"]) is not None, "invalid page tag/digest")


def validate_page(page: dict) -> None:
    """Validate page ordering/chain shape only, NOT entry admission or trust."""
    require(isinstance(page, dict) and type(page.get("schemaVersion")) is int and page["schemaVersion"] == 1 and page.get("channel") == "tip" and page.get("windowSize") == WINDOW, "unsupported payload format")
    require(isinstance(page.get("updateRepository"), str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", page["updateRepository"]) is not None, "invalid update repository")
    entries = page.get("entries")
    require(isinstance(entries, list) and 1 <= len(entries) <= WINDOW, "page must contain 1...30 entries")
    tags = set()
    previous = None
    for entry in entries:
        require(isinstance(entry, dict), "entry must be object")
        tag = entry.get("tag")
        require(isinstance(tag, str) and TAG.fullmatch(tag) is not None and tag not in tags, "invalid/duplicate tag")
        tags.add(tag)
        build = entry.get("buildNumber")
        require(isinstance(build, str), "build must be string")
        parsed = parse_build(build, "history build")
        require(previous is None or parsed < previous, "builds must strictly decrease")
        previous = parsed
        digest = entry.get("historyCatalogSha256")
        require(digest is None or isinstance(digest, str) and DIGEST.fullmatch(digest) is not None, "invalid entry catalog digest")
    require(page.get("generatedForTag") == entries[0]["tag"], "head tag mismatch")
    require(entries[0].get("historyCatalogSha256") is None, "head cannot hash itself")
    for field in ("olderPage", "archiveTail"):
        validate_reference(page.get(field))


def page_from_envelope(data: bytes) -> dict:
    """Extract an already-authenticated envelope; does not verify signatures."""
    payload, _ = extract(data)
    page = parse_json(payload)
    validate_page(page)
    return page


def assemble_page(entry: dict, repository: str, parent_bytes: bytes | None, seeds: list[dict] | None = None) -> dict:
    """Pure chain derivation; all input entries must be independently admitted.

    No seed can be silently added to an existing chain. A seed-tail reference
    points to the signed bootstrap rather than a non-existent seed catalog.
    """
    require(seeds is None or len(seeds) <= WINDOW - 1, "bootstrap exceeds 29 predecessors")
    retained = copy.deepcopy(seeds or [])
    older = None
    archive_tail = None
    if parent_bytes is not None:
        require(not seeds, "seeds only allowed at bootstrap")
        parent = page_from_envelope(parent_bytes)
        require(parent["updateRepository"] == repository, "parent repository mismatch")
        retained = copy.deepcopy(parent["entries"])
        digest = hashlib.sha256(parent_bytes).hexdigest()
        retained[0]["historyCatalogSha256"] = digest
        archive_tail = parent.get("archiveTail")
        if archive_tail is None and any(item.get("origin") == "seed" for item in retained):
            archive_tail = {"tag": parent["generatedForTag"], "sha256": digest}
        if len(retained) + 1 > WINDOW or parent.get("olderPage") is not None:
            tail = retained[WINDOW - 2] if len(retained) >= WINDOW - 1 else retained[-1]
            older = {"tag": tail["tag"], "sha256": tail["historyCatalogSha256"]} if tail.get("historyCatalogSha256") else archive_tail
            require(older is not None, "cannot paginate an unanchored seed tail")
    page = {"schemaVersion": 1, "channel": "tip", "updateRepository": repository, "generatedForTag": entry["tag"], "windowSize": WINDOW, "entries": [copy.deepcopy(entry), *retained][:WINDOW], "olderPage": older, "archiveTail": archive_tail}
    # The bootstrap anchor can be dropped once pagination no longer needs it.
    if not any(item.get("origin") == "seed" for item in page["entries"]) and (older is None or older != archive_tail):
        page["archiveTail"] = None
    validate_page(page)
    return page


def merge_pages(loaded: list[dict], older: list[dict]) -> list[dict]:
    result = copy.deepcopy(loaded)
    known = {item["tag"]: item for item in result}
    for index, item in enumerate(older):
        if item["tag"] in known:
            existing = copy.deepcopy(known[item["tag"]])
            incoming = copy.deepcopy(item)
            a = existing.pop("historyCatalogSha256", None)
            b = incoming.pop("historyCatalogSha256", None)
            # Only the older page's own head may lack its catalog digest.
            # Null elsewhere must not erase or invent a signed binding.
            require(existing == incoming and (a == b or index == 0 and b is None and a is not None), "overlapping history integrity mismatch")
        else:
            require(not result or parse_build(item["buildNumber"], "older") < parse_build(result[-1]["buildNumber"], "loaded"), "older page is not ordered")
            result.append(copy.deepcopy(item))
            known[item["tag"]] = result[-1]
    return result


def validate_live_parent(candidate: dict, live_bytes: bytes | None) -> None:
    """Fence a continuing chain. Bootstrap needs a separate admission audit.

    A 404 or caller-supplied boolean is never evidence history was not enabled.
    This contracts-only implementation intentionally cannot authorize bootstrap.
    """
    validate_page(candidate)
    require(live_bytes is not None, "Tip history parent superseded: audited bootstrap not implemented")
    expected = assemble_page(candidate["entries"][0], candidate["updateRepository"], live_bytes)
    require(candidate == expected, "Tip history parent superseded")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    lint = sub.add_parser("lint-fragments")
    lint.add_argument("--root", type=Path, required=True)
    notes = sub.add_parser("collect-notes")
    notes.add_argument("--repo", type=Path, required=True)
    notes.add_argument("--from", dest="previous", required=True)
    notes.add_argument("--to", dest="candidate", required=True)
    notes.add_argument("--output", type=Path, required=True)
    message = sub.add_parser("signed-message")
    message.add_argument("--payload", type=Path, required=True)
    message.add_argument("--output", type=Path, required=True)
    envelope = sub.add_parser("wrap")
    envelope.add_argument("--payload", type=Path, required=True)
    envelope.add_argument("--signature", required=True)
    envelope.add_argument("--output", type=Path, required=True)
    unpack = sub.add_parser("extract")
    unpack.add_argument("--envelope", type=Path, required=True)
    unpack.add_argument("--message-output", type=Path, required=True)
    unpack.add_argument("--signature-output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "lint-fragments":
            lint_fragments(args.root)
        elif args.command == "collect-notes":
            args.output.write_bytes(canonical(collect_notes(args.repo, None if args.previous == "none" else args.previous, args.candidate)))
        elif args.command == "signed-message":
            args.output.write_bytes(DOMAIN + args.payload.read_bytes())
        elif args.command == "wrap":
            args.output.write_bytes(wrap(args.payload.read_bytes(), args.signature))
        elif args.command == "extract":
            payload, signature = extract(args.envelope.read_bytes())
            args.message_output.write_bytes(DOMAIN + payload)
            args.signature_output.write_text(base64.b64encode(signature).decode() + "\n")
    except (HistoryError, RolloutError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"tip-history: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
