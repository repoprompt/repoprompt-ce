# Integration admission

## Authority and scope

`CI / Style` is the final fail-closed **integration** check, not a formatting-only
row and not permission to publish a release. The `integration-v3` profile is
implemented by the existing CI DAG, artifact verifier, and exact-test-coverage
verifier. `Scripts/ci_admission.py` carries immutable identity/policy, **not** a
second success registry. Version 1/2 receipts are rejected rather than relabelled
under the changed guarantee.

The same profile runs for PRs targeting `main`, merge queue `checks_requested`,
and main pushes. Successful integration requires all obligations (no path exemptions):

- existing static/style/secret/import/index gates, provider and module parity tests;
- one clean root test build with the existing enforcing type-check budgets;
- all four root shards with exact listing/target/assignment/union verification;
- a Sentry-enabled app build and serialized privacy tests.

Sentry/privacy remains a blocking secret-free job in `ci-integration-products.yml`,
with read-only contents permission and no inherited secrets. It starts only after
root build/static gates, all four shards and secret scan pass. Failed, skipped,
cancelled or missing obligations cannot make Style green.

### Release qualification is a separate obligation

Universal release-mode packaging and older-macOS artifact smoke no longer run for
every integration candidate. This deliberately permits a release-only regression
to merge; it must still prevent publication. A green Style is **not** evidence that
release packaging, notarization, older macOS, or Computer Use works.

- **Automatic Tip:** successful exact-main CI triggers `Publish Tip`. Its current-main
  eligibility, trusted tooling/source identity, secret-free clean universal staging,
  signing/notarization, exact packaged-helper smoke, and macOS 15 ARM64/Intel artifact
  checks remain intact. Publication waits for smoke and compatibility.
- **Stable:** `Publish Release` builds a reviewed source draft and checks its signed
  artifact; `Promote Release` verifies reviewed checksums and repeats the artifact
  gates before public promotion. Existing release environment approval is unchanged.
- **Before merging packaging changes:** explicitly run `Release Candidate` on the
  reviewed branch/commit and inspect both packaged-helper and older-runtime results.
  It remains manual, never an automatic second universal build for every push.
  The diagnostic is not a replacement for qualification of the subsequently signed
  artifact and does not itself enforce branch protection.
- **Standalone `CI (main)`:** manual Sentry diagnostics only; the same obligation
  already blocks Style. It need not be run routinely.

The manual candidate retains conductor's four-hour package deadline inside a
245-minute step / 270-minute job envelope, unbuffered logs, a private conductor state
directory, and failure diagnostic uploads. Its artifact name includes run and attempt;
compatibility consumes the successful producer's artifact-name output with exact source
tooling, including on compatibility-only diagnostic retries. If that retained archive
has expired, rerun the whole diagnostic. This reuse is not Style evidence. There
is no cross-run promotion of diagnostic artifacts into credentialed publication.

The oldest hosted-runtime matrix covers macOS 15, not macOS 14; see
[manual macOS 14 validation](../releasing.md#older-macos-artifact-compatibility).
See [the capacity audit](ci-capacity-2026-11-04.md) for why the release builds were
removed from per-candidate integration, the measured workload, and rollout limits.

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

The immutable candidate binds commit, tree, base, ref, event, run ID and policy.
It deliberately has no consumer-attempt field. Every executing job verifies its
checkout and current run. The root producer declares a separate identity before
running tests: candidate + build attempt + Swift/Xcode versions. It binds that
identity to the archive only after its gates succeed. Job outputs identify the
successful producer, not a lookup for the latest available artifact.

Workers verify the producer against the candidate, reject future attempts and
Swift/Xcode drift, then download that producer's exact run/attempt-named archive.
Each shard receipt carries the same root producer identity. The worker exports its
own run/execution-attempt-named receipt artifact. Style first requires all job
results to be successful, then selects the successful root and worker outputs and
checks expected metadata and the exact four-shard union against the root identity.
A new root build plus old worker receipts fails, even for the same commit.

Evidence uploads are immutable (no overwrite), fail if absent, and retained seven
days. Downloads stay in this workflow run, with exact names and no cross-run token,
run selector or wildcard search. Missing outputs/artifacts fail closed with rebuild
instructions. Conductor does not need `GITHUB_*` in its manifest environment.

This is correctness/provenance enforcement, not a security boundary against a PR
that edits its own workflows/scripts. Trusted-base review, required checks and
repository policy remain essential; diagnostics never grant merge authority.

Caches are acceleration, not evidence. The root cache contains dependency checkouts
and provider-package intermediates, not the root products that the enforcing
clean build discards. One exact toolchain/policy-compatible main
seed replaces per-commit multi-GB snapshots. Root cache restoration explicitly invalidates
old admission identity before selftests/builds. The build helper also invalidates
identity and timing data before a clean/rebuild, including failed cleans. A fresh
binding is written only after all producer gates pass. Hosted pack/shard/aggregate
boundaries require that binding; only non-hosted/local callers may omit it.
The Sentry lane restores checksum-verified dependency binaries only, never compiled
app products or gate metadata.

The manual Release Candidate job separately restores `.build/public-release-swiftpm`,
including both architectures' intermediates. Its exact key includes OS/architecture,
Xcode/Swift/SDK/image/workspace identity, package manifests/pins, release policy and
dependency patches. There is no fallback across these boundaries. Only an explicit
**main** diagnostic, after fresh packaging and helper smoke, can seed this cache;
branch diagnostics restore only. A policy change or eviction means a cold build.

The diagnostic sets `REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS=0` per conductor request.
SwiftPM still builds both products and architectures; app/manifest/archive creation,
resource and architecture verification, helper smoke and older-runtime checks rerun.
Assembled apps, `dist` and admission/coverage receipts are not cached. Official Tip
and stable staging remain clean; they never sign this diagnostic cache's products.
Local release commands retain their default clean behavior. Cache hits are not
build, test, or publication evidence.

## Runner capacity and scheduling

Integration requests three macOS jobs: one producer, one root-test worker running
all four logical shards sequentially, and Sentry/privacy. The earlier reduction
removed universal packaging and compatibility from nine jobs to six; consolidating
the shard workers removes another three allocations and artifact downloads. Universal packaging and its two artifact checks are demanded
only by actual release flows or an explicit diagnostic. This removes the largest
per-candidate workload amplifier; it does not reserve capacity or promise a latency
SLO. GitHub account limits and hosted image availability remain separate constraints.
The [capacity audit](ci-capacity-2026-11-04.md) separates measured queue/execution time
from expected impact. There is no measured hosted before/after result yet.

Sentry still waits for root gates to reject bad candidates before allocating a VM.
Four logical root shards keep exact full coverage. A single worker downloads and
verifies the producer once, then runs each shard with a fresh per-suite sandbox
through conductor. Ordinary shard failure does not suppress later shards; failed
setup and workflow cancellation do. No `continue-on-error` masks a failure.
Each shard has a 1,800-second conductor execution limit (owned process cleanup),
a 32-minute step envelope, and unchanged individual-suite/test assertion budgets.
The 140-minute job envelope covers four sequential steps plus setup/uploads;
it is not a relaxed individual-test timeout. All four run/attempt-bound receipts
are uploaded together and the existing Style verifier still requires their exact
union. Missing or failed shards cannot pass. This does not change the profile's
correctness obligations. Producer-bound partial reruns are described below.

This trades idle-capacity parallel speed for fewer allocations under contention.
It does not reduce the number of tests or the clean build/Sentry workload. Compare
end-to-end latency and summed macOS execution minutes for successful runs, separating
queue time from execution. Keep failed/cancelled attempts visible but out of the
successful-run timing comparison. Revert the worker consolidation if queue savings
do not offset sequential execution or state isolation regresses; do not weaken
coverage, deadlines, secret scans, or publication gates. Hosted benefit is unproven
until the new workflow runs. Existing suite isolation is unchanged, but one VM is
now reused across shards; hosted validation must specifically check this boundary.
 Do not increase
parallelism or switch images assuming that creates account capacity. Preserve the
Ubuntu Tip eligibility job so obsolete candidates do not wait for a Mac just to skip.
Main pushes remain run-scoped: coalescing the whole workflow would discard introduced
commit-range secret scans. Do not add cancellation without addressing that obligation.

### Read-only queue and execution report

Use authenticated `gh` with the repository-owned reporter; it only makes GET requests:

```sh
python3 Scripts/ci_status_report.py --run 41802322531 --run 41783464696 > /tmp/ci-timing.json
```

The report pins each run's current attempt, paginates its jobs, preserves failures
and cancellations, and separates runner allocation delay from execution. A synthetic
`started_at` with no runner ID is not executing. In-progress times are approximate snapshots (API races and clock skew apply);
future dependent jobs are absent. Unassigned skipped/cancelled jobs have unknown
queue duration, not zero. A changed/mixed attempt or incomplete job pagination fails instead of silently
combining evidence. This diagnostic does not certify partial-rerun lineage. Queue
time includes any approval or concurrency wait, not only runner-capacity pressure. Collection is a bounded snapshot, not an atomic view of GitHub.

Compare successful runs on the same profile and similar workload/queue pressure.
Use run links and per-job timestamps; summed runner seconds are not wall-clock latency
or billing. Do not compare a cancelled/partial run's short duration to a passing run.
For worker consolidation, record test-worker queue time, execution, total macOS
execution, exact coverage success, and overall time to Style. Keep a rollback available
if serialized execution outweighs queue/setup savings. No automated cancellation,
rerun, secret access, or workflow mutation is provided by this command.

Reporter regression tests run with `python3 Scripts/test_ci_admission.py` and the
existing `make ci-app-test-runner-selftest` lane.

### Reruns and cancellation

For runs created with `integration-v3`, normal **Re-run failed jobs** and
individual-job reruns are supported. Successful ancestors are reused only through
their exact producer outputs; the consumer's newer attempt number must not be used
to invent a build artifact name. A worker rerun re-executes all four shards, while a
Sentry-only rerun need not rebuild the successful root tests. Style-only retries
still require all prerequisites and independently verify the original evidence.

| Failure | Recovery |
|---|---|
| Source/lint/assertion/coverage failure | Fix the source; update the PR and inspect the new exact integration candidate. Repetition is not a fix. |
| Confirmed transient network/runner failure | Rerun the failed job/dependents or failed jobs. Inspect the original log before classifying a failure as transient. |
| Missing/expired archive, dropped output, Swift/Xcode drift | Rerun **Build and Static Gates** and dependents, or all jobs. Do not bypass Style. |
| Wrong/stale producer receipt | Rebuild and rerun dependents; mixed-build evidence must remain rejected. |
| Outdated PR base/head or unavailable synthetic merge | Update the PR branch; a rerun uses the original SHA/ref, not current main. |
| Old `integration-v1/v2` run | Re-run all jobs uses that commit's old policy. To obtain v3 behavior, update the branch and trigger fresh CI. |

GitHub [supports whole/failed/specific-job reruns](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs?tool=cli)
for 30 days (up to 50 attempts), but our seven-day evidence retention can require a
rebuild sooner. No automatic retry loop, extra write token or success registry is used.

Each job records failed step IDs and recovery guidance in its **job summary**. The
final **Style** summary lists every prerequisite before interpreting admission
outputs, so a missing declaration cannot hide a real upstream failure. Main CI
explains that unsuccessful integration blocks automatic Tip eligibility; a green
Style still does not certify a release. These reports use workflow step outcomes,
not guesses from exit codes about flakiness. Log links lead to the actual assertion,
compiler, download or infrastructure error. Missing reports (checkout failure,
runner loss, cancellation) are explicitly unknown, not proof of success. A cancelled
workflow can prevent even `always()` diagnostics; GitHub's timeline remains needed.

Only obsolete first-attempt PR previews supersede one another. Queue/main runs and
explicit reruns remain run-scoped; newer pushes do not cancel their evidence.
Whole-main-run coalescing would skip push-range secret scans and is not used.
Any failed, cancelled, skipped, or missing required obligation prevents Style success.
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
   a queue. Inspect exact-head PR checks: candidate declaration, Sentry/privacy,
   static build, all shards, secret scan, and final Style must actually execute.
2. Configure the exact `main` ruleset/branch protection to require `Style` from
   GitHub Actions and require the merge queue. Prohibit ordinary direct pushes and
   bypasses (including routine admin merges), force-pushes, and deletion. Preserve
   review/security rules. Do not point required checks at the earlier build job.
3. Initially use queue build concurrency 1 and maximum merge group size 1; choose a
   check timeout that accommodates the clean build, all shards and Sentry/privacy.
   Do not allow skipping failed entries to bless an untested prefix/integration tree.
4. Exercise a real queue entry. Verify the declaration uses its `merge_group` payload
   and temporary head, not the original PR head. Retain the queue head/tree and the
   landed main head/tree; compare trees (`git rev-parse <sha>^{tree}`), since commit
   IDs may differ. Confirm both have the full profile's results. Exercise a replaced
   candidate and confirm its old success does not authorize the replacement.
5. On a non-production PR, verify a full rerun creates new producer evidence;
   retry the root worker, Sentry and Style individually and confirm their successful
   ancestors remain reusable. Retain run/job/attempt/artifact receipts. Confirm a
   failed/skipped Sentry lane or missing/mixed-build receipt cannot produce green Style.
   This hosted exercise is required before calling native rerun recovery proven.

[GitHub's queue documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
requires workflow support for `merge_group` before queue admission can work. If the
repository cannot activate a queue, require up-to-date branches plus the full Style
profile as an explicitly recorded interim measure; do **not** claim queue/current-
candidate enforcement is active. Do not silently revert to loose status checks.
Rollback must preserve a complete premerge authority or explicitly stop merges;
removing the queue/check requirement is not a transparent implementation rollback.

## Validation

`make ci-workflow-selftest` runs admission, diagnostic and workflow-contract tests
in a separate Ubuntu job before any Mac allocation. Secret Scan depends only on
the candidate declaration: failing tooling contracts must not suppress a main
push's introduced-commit-range scan. It is also part of `make check-fast` and the
path-selected CI lane. `make ci-app-test-runner-selftest` additionally covers the
runner/coverage/dependency harness: event normalization, wrong tree/run/producer,
partial-rerun reuse and mixed-build rejection, stale-cache invalidation, required hosted identity,
clean/enforcing timing and retained outcomes, and receipt provenance/coverage.
`make conductor-selftest`, `make guardrails`, and actionlint cover the affected local
boundaries. The contribution preflight selects the hosted-runner suite for these
workflow/profile/artifact paths. Real GitHub queue/rerun behavior, universal packaging,
Sentry linking, and release-workflow macOS packaged smoke still require hosted proof; local Python
success alone is not equivalent to those checks.

See the [reliability incident and recovery validation](ci-capacity-2026-11-04.md#reliability-incident-and-recovery)
for the confirmed tooling regression, old partial-rerun dead end and remaining limits.
