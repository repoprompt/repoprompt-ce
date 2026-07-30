#!/usr/bin/env python3
"""Validate the manual, read-only Codex candidate evidence workflow contract."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WORKFLOW = ROOT / ".github" / "workflows" / "codex-update-candidate.yml"
CHECKOUT_ACTION = "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
UPLOAD_ACTION = "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
EXPECTED_STEP_NAMES = (
    "Check out trusted main",
    "Validate candidate selector",
    "Prepare guarded candidate evidence",
    "Upload candidate evidence",
)
EXPECTED_SELECTOR_LINES = (
    "set -euo pipefail",
    "count=0",
    "args=()",
    'if [[ -n "$INPUT_VERSION" ]]; then',
    "count=$((count + 1))",
    'args+=(--version "$INPUT_VERSION")',
    "fi",
    'if [[ -n "$INPUT_TAG" ]]; then',
    "count=$((count + 1))",
    'args+=(--tag "$INPUT_TAG")',
    "fi",
    'if [[ "$INPUT_LATEST" == "true" ]]; then',
    "count=$((count + 1))",
    "args+=(--latest-stable)",
    "fi",
    'if [[ "$count" -ne 1 ]]; then',
    'echo "Set exactly one of version, tag, or latest_stable." >&2',
    "exit 1",
    "fi",
    'printf \'%s\\0\' "${args[@]}" > "$RUNNER_TEMP/codex-candidate-selector"',
)
EXPECTED_CANDIDATE_LINES = (
    "set -euo pipefail",
    "args=()",
    'while IFS= read -r -d \'\' value; do args+=("$value"); done < "$RUNNER_TEMP/codex-candidate-selector"',
    "python3 Scripts/codex_update_candidate.py \\",
    '"${args[@]}" \\',
    "--output-dir .build/codex-update-candidate/evidence",
)
MAPPING_PATTERN = re.compile(r"([A-Za-z0-9_-]+):(?:[ ]*(.*))?")


class WorkflowContractError(RuntimeError):
    pass


def indentation(line: str) -> int:
    if "\t" in line[: len(line) - len(line.lstrip())]:
        raise WorkflowContractError("workflow indentation must not contain tabs")
    return len(line) - len(line.lstrip(" "))


def mapping_at(lines: Sequence[str], indent: int) -> dict[str, tuple[str, int]]:
    result: dict[str, tuple[str, int]] = {}
    prefix = " " * indent
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#") or indentation(line) != indent:
            continue
        raw = line[len(prefix) :]
        match = MAPPING_PATTERN.fullmatch(raw)
        if match is None:
            raise WorkflowContractError(f"expected a mapping at line {index + 1}: {line!r}")
        key, value = match.group(1), match.group(2) or ""
        if key in result:
            raise WorkflowContractError(f"duplicate workflow key at indentation {indent}: {key}")
        result[key] = value, index
    return result


def block_for(lines: Sequence[str], key: str, indent: int) -> list[str]:
    entries = mapping_at(lines, indent)
    if key not in entries:
        raise WorkflowContractError(f"missing workflow key: {key}")
    _value, start = entries[key]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].strip() and indentation(lines[index]) <= indent:
            end = index
            break
    return list(lines[start:end])


def scalar(value: str) -> str:
    stripped = value.strip()
    if len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {"'", '"'}:
        return stripped[1:-1]
    return stripped


def step_blocks(lines: Sequence[str]) -> list[tuple[str, list[str]]]:
    starts: list[int] = []
    names: list[str] = []
    for index, line in enumerate(lines):
        if not line.strip() or indentation(line) != 6:
            continue
        match = re.fullmatch(r" {6}- name:[ ]*(.+)", line)
        if match is None:
            raise WorkflowContractError(f"unexpected step entry: {line!r}")
        starts.append(index)
        names.append(scalar(match.group(1)))
    blocks: list[tuple[str, list[str]]] = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        blocks.append((names[position], list(lines[start:end])))
    return blocks


def block_scalar_text(lines: Sequence[str], key: str, indent: int) -> str:
    entries = mapping_at(lines, indent)
    value, start = entries.get(key, ("", -1))
    if start < 0 or value not in {"|", "|-", ">", ">-"}:
        raise WorkflowContractError(f"step must contain a block scalar {key}")
    content: list[str] = []
    for line in lines[start + 1 :]:
        if line.strip() and indentation(line) <= indent:
            break
        if line.strip():
            content.append(line.strip())
    return "\n".join(content)


def validate_workflow(path: Path = DEFAULT_WORKFLOW) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise WorkflowContractError(f"could not read workflow {path}: {exc}") from exc
    lines = text.splitlines()

    root = mapping_at(lines, 0)
    if set(root) != {"name", "on", "permissions", "jobs"}:
        raise WorkflowContractError(f"unexpected root workflow keys: {sorted(set(root))}")

    triggers = mapping_at(block_for(lines, "on", 0)[1:], 2)
    if set(triggers) != {"workflow_dispatch"}:
        raise WorkflowContractError(
            f"Codex candidate workflow must have only workflow_dispatch; found {sorted(triggers)}"
        )

    permissions = mapping_at(block_for(lines, "permissions", 0)[1:], 2)
    permission_values = {key: scalar(value) for key, (value, _index) in permissions.items()}
    if permission_values != {"contents": "read"}:
        raise WorkflowContractError(
            f"Codex candidate workflow permissions must be exactly contents: read; found {permission_values}"
        )

    jobs_block = block_for(lines, "jobs", 0)
    jobs = mapping_at(jobs_block[1:], 2)
    if set(jobs) != {"evidence"}:
        raise WorkflowContractError(f"workflow must contain only the evidence job; found {sorted(jobs)}")
    evidence = block_for(jobs_block[1:], "evidence", 2)
    evidence_mapping = mapping_at(evidence[1:], 4)
    if set(evidence_mapping) != {"name", "if", "runs-on", "steps"}:
        raise WorkflowContractError(f"unexpected evidence job keys: {sorted(evidence_mapping)}")
    if scalar(evidence_mapping["if"][0]) != "github.ref == 'refs/heads/main'":
        raise WorkflowContractError("evidence job must be gated to refs/heads/main")
    if scalar(evidence_mapping["runs-on"][0]) != "macos-26":
        raise WorkflowContractError("evidence job must run on macos-26")

    steps = step_blocks(block_for(evidence[1:], "steps", 4)[1:])
    if tuple(name for name, _block in steps) != EXPECTED_STEP_NAMES:
        raise WorkflowContractError(f"unexpected workflow steps: {[name for name, _block in steps]}")
    by_name = {name: block for name, block in steps}

    checkout = by_name[EXPECTED_STEP_NAMES[0]]
    checkout_mapping = mapping_at(checkout[1:], 8)
    if scalar(checkout_mapping.get("uses", ("", 0))[0]) != CHECKOUT_ACTION:
        raise WorkflowContractError("checkout action must remain SHA-pinned")
    checkout_with = mapping_at(block_for(checkout[1:], "with", 8)[1:], 10)
    if {key: scalar(value) for key, (value, _index) in checkout_with.items()} != {
        "persist-credentials": "false"
    }:
        raise WorkflowContractError("checkout must set only persist-credentials: false")

    selector_text = block_scalar_text(by_name[EXPECTED_STEP_NAMES[1]][1:], "run", 8)
    if tuple(selector_text.splitlines()) != EXPECTED_SELECTOR_LINES:
        raise WorkflowContractError("selector step command contract drifted")

    candidate_text = block_scalar_text(by_name[EXPECTED_STEP_NAMES[2]][1:], "run", 8)
    if tuple(candidate_text.splitlines()) != EXPECTED_CANDIDATE_LINES:
        raise WorkflowContractError("official candidate command contract drifted")

    upload = by_name[EXPECTED_STEP_NAMES[3]]
    upload_mapping = mapping_at(upload[1:], 8)
    if scalar(upload_mapping.get("uses", ("", 0))[0]) != UPLOAD_ACTION:
        raise WorkflowContractError("upload-artifact action must remain SHA-pinned")
    upload_with = mapping_at(block_for(upload[1:], "with", 8)[1:], 10)
    upload_values = {key: scalar(value) for key, (value, _index) in upload_with.items()}
    if upload_values != {
        "name": "RepoPrompt-CE-Codex-runtime-update-candidate",
        "path": ".build/codex-update-candidate/evidence",
        "if-no-files-found": "error",
    }:
        raise WorkflowContractError(f"upload evidence contract drifted: {upload_values}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", default=str(DEFAULT_WORKFLOW))
    args = parser.parse_args(argv)
    try:
        validate_workflow(Path(args.workflow))
    except WorkflowContractError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"OK: Codex update workflow is manual, main-only, read-only, and artifact-only: {args.workflow}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
