#!/usr/bin/env python3
"""Select an exact passing main-push CI source when a queued Tip run starts."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path


PAGE_SIZE = 100
MAX_PAGES = 3
CI_PATH = ".github/workflows/ci.yml"
_NO_TRIGGER = object()


class SelectionError(ValueError):
    pass


def positive_integer(value: object) -> bool:
    return type(value) is int and value > 0


def qualified_run(run: object, repository: str) -> dict | None:
    if not isinstance(run, dict):
        raise SelectionError("CI search returned a malformed workflow run")
    if (
        run.get("event") != "push"
        or run.get("head_branch") != "main"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or str(run.get("path", "")).split("@", 1)[0] != CI_PATH
    ):
        return None
    for key in ("repository", "head_repository"):
        origin = run.get(key)
        if not isinstance(origin, dict) or origin.get("full_name") != repository:
            return None
    commit = run.get("head_sha")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SelectionError("Passing main CI is missing a full lowercase source SHA")
    if not positive_integer(run.get("id")) or not positive_integer(run.get("run_attempt")):
        raise SelectionError("Passing main CI is missing its run/attempt identity")
    return {
        "commit": commit,
        "run_id": run["id"],
        "run_attempt": run["run_attempt"],
        "url": f"https://github.com/{repository}/actions/runs/{run['id']}",
    }


def fetch_page(repository: str, page: int) -> dict:
    endpoint = (
        f"/repos/{repository}/actions/workflows/ci.yml/runs"
        f"?branch=main&event=push&status=success&per_page={PAGE_SIZE}&page={page}"
    )
    try:
        result = subprocess.run(
            ["gh", "api", endpoint], text=True, capture_output=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SelectionError("Unable to read recent main CI runs from GitHub") from error
    if result.returncode:
        raise SelectionError(f"GitHub main CI lookup failed (exit {result.returncode})")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SelectionError("GitHub main CI lookup returned invalid JSON") from error


def select(
    repository: str,
    main_history: list[str],
    reader: Callable[[str, int], dict] = fetch_page,
    *,
    trigger_event: object = _NO_TRIGGER,
) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SelectionError("Repository must be an owner/name slug")
    if not main_history or any(not re.fullmatch(r"[0-9a-f]{40}", sha) for sha in main_history):
        raise SelectionError("Protected-main first-parent history is unavailable")
    positions = {sha: index for index, sha in enumerate(main_history)}
    candidates: list[dict] = []
    if trigger_event is not _NO_TRIGGER:
        if (
            not isinstance(trigger_event, dict)
            or trigger_event.get("action") != "completed"
            or not isinstance(trigger_event.get("repository"), dict)
            or trigger_event["repository"].get("full_name") != repository
        ):
            raise SelectionError("Tip trigger must be a completed workflow event from the source repository")
        trigger = qualified_run(trigger_event.get("workflow_run"), repository)
        if trigger is None:
            raise SelectionError("Tip trigger must be successful source-repository main-push CI")
        if trigger["commit"] not in positions:
            raise SelectionError("Tip trigger is outside protected-main first-parent ancestry")
        candidates.append(trigger)
    inspected = 0
    complete = False
    for page in range(1, MAX_PAGES + 1):
        payload = reader(repository, page)
        if not isinstance(payload, dict):
            raise SelectionError("GitHub main CI lookup must return an object")
        total = payload.get("total_count")
        runs = payload.get("workflow_runs")
        if type(total) is not int or total < 0 or not isinstance(runs, list) or len(runs) > PAGE_SIZE:
            raise SelectionError("GitHub main CI lookup has invalid pagination metadata")
        inspected += len(runs)
        for run in runs:
            candidate = qualified_run(run, repository)
            if candidate is not None and candidate["commit"] in positions:
                candidates.append(candidate)
        complete = page * PAGE_SIZE >= total
        if not complete and len(runs) != PAGE_SIZE:
            raise SelectionError("GitHub main CI search returned an incomplete page")
        if complete or any(candidate["commit"] == main_history[0] for candidate in candidates):
            break
    if not candidates:
        scope = "retained CI history" if complete else f"bounded {MAX_PAGES * PAGE_SIZE}-run search"
        raise SelectionError(
            f"No successful main-push CI source in protected-main first-parent ancestry was found in {scope}; "
            "wait for a fresh successful main CI run. Untested main was not selected."
        )
    candidate = min(candidates, key=lambda row: (positions[row["commit"]], -row["run_id"], -row["run_attempt"]))
    return {**candidate, "inspected_runs": inspected, "search_complete": complete}


def git_output(*arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", *arguments], check=True, text=True, capture_output=True, timeout=15,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise SelectionError("Unable to establish pinned protected-main history") from error
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--main-commit", required=True)
    parser.add_argument("--event-path", required=True)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.main_commit):
            raise SelectionError("Main commit must be a full lowercase SHA")
        if git_output("rev-parse", "HEAD") != args.main_commit:
            raise SelectionError("CI selection must run from the pinned protected-main tooling checkout")
        history = git_output("rev-list", "--first-parent", args.main_commit).splitlines()
        try:
            trigger_event = json.loads(Path(args.event_path).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise SelectionError("Unable to read GitHub workflow event JSON") from error
        result = select(args.repository, history, trigger_event=trigger_event)
    except SelectionError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
