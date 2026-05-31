---
name: rpce-contribution-check
description: Validate RepoPrompt CE contributions before committing or pushing. Use whenever an agent is about to create a commit, push the current branch, rewrite history, delete a branch or fork, or change GitHub-visible repository state. Enforces staged-index and outgoing-range secret scanning, repository guardrails, relevant coordinated validation lanes, clean push boundaries, and explicit approval for destructive Git or visible live-app operations.
---

# RepoPrompt CE Contribution Check

Run the repository-local preflight before every commit and push. Read `AGENTS.md` first and use daemon-coordinated validation where available.

## Before committing

1. Review `git status --short` and inspect the intended diff.
2. Stage only intended files. Review `git diff --cached --stat` and `git diff --cached`.
3. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
```

4. Rerun commit preflight after any staging change, including partial-staging updates. Commit mode scans materialized staged index blobs, not merely working-tree copies.
5. Keep secret values redacted in terminal output and summaries.

## Before pushing

1. Ensure the working tree is clean.
2. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

3. Review the computed current-branch range printed by the script.
4. Read [references/validation-matrix.md](references/validation-matrix.md) and ensure any required evidence is recorded before pushing.
5. Push only the intended current branch and check the GitHub Actions run after pushing.

Push mode validates only the current branch against its configured upstream. For a non-`main` topic branch without a configured upstream, it may use `origin/main` as an explicit comparison fallback. It does not validate tags, `--all`, `--mirror`, or arbitrary refspecs.

## Escalate before destructive operations

Obtain explicit user approval immediately before force-push, history rewrite, branch deletion, fork deletion, credential rotation, any other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app. Do not bundle approval for a future destructive step into an earlier request.

When removing exposed credentials, revoke or rotate them even after rewriting history. Scan forks and cached GitHub commit access without printing decoded values.

## Focused validation

Read [references/validation-matrix.md](references/validation-matrix.md) when deciding whether additional focused tests, builds, live smoke, or GitHub Support cleanup are required.
