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

- **Automatic Tip:** successful main-push CI triggers `Publish Tip`. When its rolling
  queue starts, it selects the newest passing source from the authenticated
  triggering event and at most 300 recent successful CI runs, ordered by pinned
  protected-main first-parent ancestry. The event closes a list-API visibility race.
  A newer untested main commit does not suppress that qualified ancestor. The exact
  source CI run/attempt and the separately pinned main tooling SHA are recorded.
  Already-published or newer-published sources skip before Mac allocation. Its
  source authorization, secret-free clean universal staging,
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

The immutable candidate binds commit, tree, base, ref, event, run ID and policy,
including `root_architecture: arm64` for the clean-enforcing timing protocol.
It deliberately has no consumer-attempt field. Every executing job verifies its
checkout and current run. The root producer declares a separate identity before
running tests: candidate + build attempt + architecture + Swift/Xcode versions. It binds that
identity to the archive only after its gates succeed. Job outputs identify the
successful producer, not a lookup for the latest available artifact.

Workers verify the producer against the candidate, reject future attempts and
architecture/Swift/Xcode drift, then download that producer's exact run/attempt-named archive.
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

Integration retains the standard `macos-26` ARM pool used before PR #1628.
The root producer and worker must run on the same architecture, recorded in the
producer identity and checked before downloading/executing its archive.
Dependency/cache keys already include architecture. Sentry and Xcode workspace
validation also retain ARM. These jobs explicitly select
`/Applications/Xcode_26.6.app/Contents/Developer`, the toolchain in the last accepted
hosted ARM control, rather than silently following a runner image's new default.
Root producer admission rejects a different architecture before dependency work
or compilation, emits its architecture/Swift/Xcode identity, and does not suggest
rerunning a platform-policy mismatch. A future platform/toolchain change needs
reviewed timing and native-coverage evidence; missing pinned Xcode fails rather
than falling back. No automatic architecture fallback duplicates work or accepts
another architecture's compiled evidence. Universal release builds and both
ARM/Intel older-runtime publication checks remain unchanged.

PR #1628 experimented with `macos-26-intel` after confirmed ARM allocation
failures. The latest inspected Intel build at head `a3b9d1053` compiled successfully,
but failed the unchanged clean-enforcing type-check gate: 20 slow function bodies
against a limit of 10 and 7 slow expressions against 6
([run 41920460399](https://github.com/repoprompt/repoprompt-ce/actions/runs/41920460399)).
The experiment has been rolled back rather than raising limits or accepting the
loss of ARM-native integration coverage without a passing replacement. This is
not proof that architecture caused every timing difference, that ARM will pass,
or that ARM capacity has recovered. A fresh hosted pass and recovery exercise
remain required. Account concurrency and provider availability are still external
constraints; changing a label does not create capacity.

A failed root build now prints the retained log tail, including non-compiler gate
errors, and summarizes fresh compiler exit status, timing counts and warning
counts in the step summary. Compilation success is not static-gate success.
Malformed/missing measurements do not infer success or replace the original
nonzero build exit status; the full log and timing artifact remain available.

Integration requests six macOS jobs: one producer, four independent root-test
workers, and Sentry/privacy. The #1623 single-worker experiment is reverted: it
reduced allocations, but its end-to-end benefit was not demonstrated and it removed
available shard overlap. The build-once producer predates that experiment and is
retained; no worker recompiles. Universal packaging and its two artifact checks
remain release-only. See the [rollback decision](ci-reliability-2026-11-05.md#selective-rollback-of-unproven-worker-consolidation).

Sentry still waits for root gates to reject bad candidates before allocating a VM.
The four-shard matrix uses `fail-fast: false` and a separate concurrency group per
shard, so a sibling cannot serialize or evict another sibling. Each worker verifies
the same root producer, retains the 1,800-second conductor execution deadline and
32-minute step envelope, and has a 40-minute job envelope for setup and uploads.
No test assertion or coverage requirement is relaxed. Setup failures do not start
tests, and ordinary shard failures do not cancel siblings.

Each matrix worker emits uniquely keyed artifact and diagnostic outputs. Style
requires all four exact shard/run/attempt artifact names, including successful
ancestors of partial retries, and verifies every receipt against the same root
producer plus the exact test union. It never discovers evidence by a wildcard or
chooses the newest artifact. Missing outputs or failed/stale receipts cannot pass.

Parallel scheduling restores overlap when capacity is available; it does not
create capacity. Four transfers and allocations cost more than one. Compare
complete passing runs, including queue time, summed execution and time to Style;
no speedup is claimed before hosted evidence. Preserve the Ubuntu Tip eligibility
job so obsolete candidates do not wait for a Mac just to skip.
Main workflows remain run-scoped so every introduced-commit-range secret scan can
finish. First-attempt main **Mac stages** use separate concurrency groups: one
running and one pending build, each individual shard, and Sentry job. Running work finishes;
the newest queued request replaces the previous pending request. PR previews,
merge-group candidates and explicit reruns do not share these main groups.
GitHub orders pending replacement by arrival, not commit ancestry. If an old
request arrives late and evicts the current main candidate, the bounded recovery
controller recognizes the exact system annotation and retries that job under its
run-specific retry group. Ordinary user cancellation is not reversed. Per-shard
coalescing is not atomic: a superseded candidate can execute some shards while
others are evicted. Its completed work cannot pass incomplete coverage and may
consume capacity; include that wasted work in the hosted capacity comparison.

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
For worker scheduling, record each shard's queue time, stage wall time, total macOS
execution, exact coverage success, and overall time to Style. Compare restored
parallel execution against the recorded serial baseline, not job count alone. No automated cancellation,
rerun, secret access, or workflow mutation is provided by this command.

Reporter regression tests run with `python3 Scripts/test_ci_admission.py` and the
existing `make ci-app-test-runner-selftest` lane.

### Reruns and cancellation

For runs created with `integration-v3`, normal **Re-run failed jobs** and
individual-job reruns are supported. Successful ancestors are reused only through
their exact producer outputs; the consumer's newer attempt number must not be used
to invent a build artifact name. A matrix-worker rerun re-executes that shard only;
successful siblings retain their own artifact outputs. A Sentry-only rerun need not
rebuild the successful root tests. Style-only retries
still require all prerequisites and independently verify the original evidence.

| Failure | Recovery |
|---|---|
| Source/lint/assertion/coverage failure | Fix the source; update the PR and inspect the new exact integration candidate. Repetition is not a fix. |
| Recognized hosted-runner startup or artifact-transport failure | CI Recovery retries failed jobs within its attempt budget, retaining successful jobs. Unrecognized failures need diagnosis. |
| Wrong runner architecture or unavailable pinned Xcode | Repair the platform configuration. Admission fails before expensive work; an unchanged rebuild cannot fix this policy mismatch. |
| Missing/expired archive or Swift/Xcode drift on the admitted architecture | CI Recovery rebuilds the successful root producer and dependents once when exact diagnostics and artifact history prove this cause. |
| Dropped producer output or exhausted automatic recovery | Re-run **Build and Static Gates** and dependents after inspecting the cause. |
| Current main evicted from a pending Mac stage | CI Recovery retries the specific stage only when a system annotation identifies the matching main concurrency group. Obsolete main work stays superseded. |
| Wrong/stale producer receipt | Rebuild and rerun dependents; mixed-build evidence must remain rejected. |
| Outdated PR base/head or unavailable synthetic merge | Update the PR branch; a rerun uses the original SHA/ref, not current main. |
| Old `integration-v1/v2` run | Re-run all jobs uses that commit's old policy. To obtain v3 behavior, update the branch and trigger fresh CI. |

GitHub [supports whole/failed/specific-job reruns](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs?tool=cli)
for 30 days (up to 50 attempts), but our seven-day evidence retention can require a
rebuild sooner. `CI Recovery` handles recognized infrastructure/evidence failures
after completion, with a cap of **three total source-run attempts and one successful
root-producer rebuild**. A controller API error, ambiguous evidence, exhausted
budget or unconfirmed rerun submission produces an explicit summary. There is no
success registry and no assertion/lint/compiler/coverage retry policy.

The controller runs only trusted default-branch code with `contents: read`,
`actions: write`, `checks: read` and `pull-requests: read`. It verifies the workflow
ID/path, repository, event, source attempt, latest branch CI and current main or
open same-repository PR. For PRs it checks the immutable local reusable-workflow
merge SHA and its actual parents against the current PR base/head; nested PR refs
in a workflow-run response are mutable and cannot establish original provenance.
It rechecks freshness immediately before submitting a rerun. Forks and merge-group
runs remain outside automatic recovery; their ordinary native reruns still work.
Job IDs are not check-run IDs: startup annotations are read using the validated
same-repository `check_run_url`. Zero steps alone never establish a transient error.

Each job records failed step IDs and recovery guidance in its **job summary**. The
final **Style** summary lists every prerequisite before interpreting admission
outputs, so a missing declaration cannot hide a real upstream failure. Main CI
explains that unsuccessful integration blocks automatic Tip eligibility; a green
Style still does not certify a release. These reports use workflow step outcomes,
not guesses from exit codes about flakiness. Log links lead to the actual assertion,
compiler, download or infrastructure error. Missing reports (checkout failure,
runner loss, cancellation) are explicitly unknown, not proof of success. A cancelled
workflow can prevent even `always()` diagnostics; GitHub's timeline remains needed.

Obsolete first-attempt PR previews supersede one another. Main coalescing is
restricted to pending Mac stages; independent push scans and already running work
remain intact. Queue runs and explicit reruns remain run-scoped.
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

`make ci-portable-selftest` runs portable conductor, CI and release tooling tests
once in the Ubuntu **Portable Checks** job before Mac allocation, followed by the
pinned Codex schema contract. `make ci-workflow-selftest` covers admission,
recovery, diagnostics and cross-workflow contracts and remains part of
`make check-fast` and the path-selected CI lane. Secret Scan depends only on the
candidate declaration; portable failures cannot suppress an introduced-range scan.
Both cheap gates must pass before the Mac producer starts.

Compiler-dependent guardrails, native process supervision, Apple `plutil`/ICU
tests, the real unsigned-archive rejection test and native IndexStore binding stay
on macOS (`make guardrails`, `make ci-macos-selftest`). Moving a decorated native
test to Linux must not silently replace its execution with a skip.
`make ci-app-test-runner-selftest` additionally covers the
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
The [November 5 diagnosis and repair](ci-reliability-2026-11-05.md) records the
larger historical sample, release liveness fixes, automatic recovery boundaries,
and required hosted acceptance.
