# Integration admission

## Authority and scope

`CI / Style` is the final fail-closed integration check, not a formatting-only row.
The `integration-v1` profile is implemented by the existing CI DAG, artifact
verifier, and exact-test-coverage verifier. `Scripts/ci_admission.py` carries only
immutable identity/policy, **not** a second success registry.

The same profile runs for PRs targeting `main`, merge queue `checks_requested`,
and main pushes. Every candidate runs all obligations (no path-based exemptions):

- existing static/style/secret/import/index gates, provider and module parity tests;
- one clean root test build with the existing enforcing type-check budgets;
- all four root shards with exact listing/target/assignment/union verification;
- Sentry-enabled app build and serialized privacy tests;
- universal ad-hoc **release-mode**, Sentry-enabled packaging and the exact packaged
  MCP helper roundtrip via the existing release scripts.

The last two obligations live in `ci-integration-products.yml`, called by CI with
no inherited secrets and read-only contents permission. They are prerequisites of
Style. Signing identities, notarization, Sentry publication, releases, tags, and
promotion remain independent credentialed workflows. This check does not establish
notarization, Computer Use release compatibility, or a distributable artifact.
Existing main-only Sentry/candidate workflows remain supplemental; their scheduling
and recovery changes are intentionally outside this admission change.

The universal packaging operation retains conductor's four-hour deadline. Its
workflow step allows 245 minutes and the job allows 270 minutes, so the operation
can report its own timeout and leave time for smoke and diagnostic upload. A
two-hour outer job deadline previously cancelled a still-running package on main
(run `41206584853`). This changes the runner envelope, not compiler budgets or
admission obligations. The secret-free package job uses unbuffered Python output
and an isolated conductor state directory. It retains raw job logs alongside the
manifest and smoke diagnostics, including when packaging fails; a missing
manifest must not also discard the build's failure evidence.

## Candidate and evidence boundaries

PRs check out `github.sha` (the synthetic merge), never just the topic head.
Queue events require the payload's `head_sha` and fully-qualified `head_ref` to
match `GITHUB_SHA` and `GITHUB_REF`, and `base_ref == refs/heads/main`. Pushes use
`before` and `after`. A real, available ancestor base is required. The secret
commit scan uses **base..candidate**, including the complete merge group, followed
by the checked-out source-tree scan. There is no zero-base/unbounded fallback.

GitHub documents the [merge-group SHA/ref event contract](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#merge_group);
the [Octokit payload example](https://github.com/octokit/webhooks/blob/main/payload-examples/api.github.com/merge_group/checks_requested.payload.json)
shows the fully-qualified head/base refs used here.

The profile binds commit, tree, base, ref, event, run ID, and attempt. Every job
verifies the checked-out commit/tree and current run/attempt explicitly before
work. Conductor does not need to forward `GITHUB_*` or churn manifest environments.
The root build packs the binding alongside its existing gate metadata. Each shard
extends its existing execution receipt with that binding and producer identity;
Style verifies those against independently downloaded expected coverage. Artifacts
are named by run **and attempt**. No cross-run/event promotion is supported.

Caches are acceleration, not evidence. Root cache restoration explicitly invalidates
old admission identity before selftests/builds. The build helper also invalidates
identity and timing data before a clean/rebuild, including failed cleans. A fresh
binding is written only after all producer gates pass. Hosted pack/shard/aggregate
boundaries require that binding; only non-hosted/local callers may omit it.
The Sentry lane restores checksum-verified dependency binaries only, never compiled
app products or gate metadata.

### Reruns and cancellation

Use **Re-run all jobs**. Failed-jobs-only and individually rerun jobs are deliberately
unsupported in v1: they retain an earlier candidate declaration and fail with a
`Re-run all jobs` instruction. The final aggregate independently checks the attempt,
so successful prerequisites from another attempt cannot silently satisfy it. This
is a bounded, explicit whole-profile policy, not unverified earlier-producer reuse.

Only obsolete first-attempt PR previews supersede one another. Queue/main runs and
explicit reruns are run-scoped; newer pushes do not cancel their evidence. Any
failed, cancelled, skipped, or missing required obligation prevents Style success.
A removed/replaced queue candidate cannot authorize a different candidate.

## Timing policy

PR, queue, and main use `TYPECHECK_RATCHET_ENFORCE=1`, which cleans before compiling.
There is no main-only timing blocker, tolerance, baseline increase, or retry on a
ratchet failure. `typecheck-timing-<run>-<attempt>` retains per-location maxima,
counts, the unchanged budget, policy, and compiler exit status on both ordinary
success and failure (14 days). Missing/aborted compilation is not a valid sample;
clean failure clears prior measurements rather than uploading an old sample.
Thresholds remain CPU-time-sensitive; the change does not claim to eliminate runner
variance. Reclassification or a different measurement protocol requires a separate,
evidence-led policy decision. The 200001-file test contract is unchanged here.

## Gated rollout (maintainer action; not performed by this PR)

1. Land recovery separately, then deploy this workflow support **before** requiring
   a queue. Inspect exact-head PR checks: candidate declaration, both product jobs,
   static build, all shards, secret scan, and final Style must actually execute.
2. Configure the exact `main` ruleset/branch protection to require `Style` from
   GitHub Actions and require the merge queue. Prohibit ordinary direct pushes and
   bypasses (including routine admin merges), force-pushes, and deletion. Preserve
   review/security rules. Do not point required checks at the earlier build job.
3. Initially use queue build concurrency 1 and maximum merge group size 1; choose a
   check timeout that accommodates the full clean build and universal package lane.
   Do not allow skipping failed entries to bless an untested prefix/integration tree.
4. Exercise a real queue entry. Verify the declaration uses its `merge_group` payload
   and temporary head, not the original PR head. Retain the queue head/tree and the
   landed main head/tree; compare trees (`git rev-parse <sha>^{tree}`), since commit
   IDs may differ. Confirm both have the full profile's results. Exercise a replaced
   candidate and confirm its old success does not authorize the replacement.
5. Verify a full-profile rerun succeeds only with the new attempt's products and
   receipts; a failed-jobs-only rerun must fail explicitly. Confirm a failed/skipped
   product lane or missing/wrong-attempt receipt cannot produce a green Style.

[GitHub's queue documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
requires workflow support for `merge_group` before queue admission can work. If the
repository cannot activate a queue, require up-to-date branches plus the full Style
profile as an explicitly recorded interim measure; do **not** claim queue/current-
candidate enforcement is active. Do not silently revert to loose status checks.
Rollback must preserve a complete premerge authority or explicitly stop merges;
removing the queue/check requirement is not a transparent implementation rollback.

## Validation

`make ci-app-test-runner-selftest` covers event normalization, wrong tree/run/attempt,
explicit partial-rerun rejection, stale-cache invalidation, required hosted identity,
clean/enforcing timing and retained outcomes, and receipt provenance/coverage.
`make conductor-selftest`, `make guardrails`, and actionlint cover the affected local
boundaries. The contribution preflight selects the hosted-runner suite for these
workflow/profile/artifact paths. Real GitHub queue/rerun behavior, universal packaging,
Sentry linking, and macOS packaged smoke still require hosted proof; local Python
success alone is not equivalent to those checks.
