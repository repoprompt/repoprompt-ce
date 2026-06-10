---
name: rpce-contribution-check
description: Validate RepoPrompt CE contributions before committing or pushing, and guide a brief final cleanup before opening or updating a pull request. Use whenever an agent is about to create a commit, publish contribution work, push the current branch, rewrite history, delete a branch or fork, or change GitHub-visible repository state. Guides a final scope and test-value pass, then enforces staged-index and outgoing-range secret scanning, repository guardrails, relevant coordinated validation lanes, clean push boundaries, and explicit approval for destructive Git or visible live-app operations.
---

# RepoPrompt CE Contribution Check

Run the repository-local preflight before every commit and push. Read `AGENTS.md` first and use daemon-coordinated validation where available.

## Final cleanup pass

Once implementation is substantially complete, review the complete branch diff against its intended base plus any uncommitted changes. Treat this as a judgment pass, not a line-count target or an invitation to refactor unrelated code.

- Confirm every changed file supports the requested behavior, necessary validation, or durable documentation.
- Remove abandoned approaches, temporary diagnostics, redundant helpers, speculative abstractions, accidental public/configuration surface, and incidental formatting or refactors.
- If tests, diagnostics, or smoke coverage changed, read [`../rpce-test-quality/SKILL.md`](../rpce-test-quality/SKILL.md). Keep distinct coverage for meaningful current contracts; remove exploratory, duplicate, source-shape, no-crash, report-only, or otherwise low-signal checks.
- Defer unrelated cleanup to separate work. Keep support code and tests that are justified by the target change.

Aim to minimize maintenance surface and scope, not raw diff size. Perform this pass once near the end and repeat only if later changes materially alter the diff.

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

## Focused validation

Read [references/validation-matrix.md](references/validation-matrix.md) when deciding whether additional focused tests, builds, or live smoke are required.
