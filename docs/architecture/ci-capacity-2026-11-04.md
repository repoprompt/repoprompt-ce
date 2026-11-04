# RepoPrompt CE CI/release capacity audit — 2026-11-04

This audit records the pre-change source/history and the approved repair boundary.
The accompanying change implements `integration-v2`: core and Sentry/privacy remain
blocking; universal package and older-runtime smoke qualify release artifacts rather
than every integration. The manual candidate retains the former diagnostic job's
bounded execution, exact cache key and failure logs. Published release workflows,
server-side rules, runner capacity, secrets and live jobs are unchanged.

The structural change is nine to six macOS jobs per successful integration. This is
not a hosted latency result. No post-rollout before/after performance is claimed.
Rollback restores the prior versioned profile and release-product jobs, not weaker
publication gates. Known limitations and subsequent decisions are listed below.

## Provenance and method

- Current source inspected: `0698acae35f73f555b1ebfba7281ee2af7b982dd`.
- Reference tags: v1.6.0 (`0486357ac274902c6c9459c567239a2eab9294e8`, October 11)
  and v1.7.0 (`3253f289a69a366b3e55bd28f47d024f932d77a5`, October 27).
- Read-only GitHub API snapshots collected November 4, beginning 04:01 UTC.
  Recent states are time-specific and may change. Raw JSON/logs were retained locally;
  linked runs and public commits are the reproducible source references.
- All 603 CI run records created October 11–27 retrieved with pagination; all
  131 records October 31–November 4 visible during the second capture retrieved.
  These are run records, not distinct attempts or immutable outcome cohorts.
- Detailed attempt-specific jobs inspected for representative success, failure,
  cancellation, rerun, slow CI, Tip and stable-release cases.
- Queue interval = job.started_at minus job.created_at, only for assigned jobs
  with consistent timestamps from the selected attempt. Execution = completed_at
  minus started_at. Dependency wait before job creation is not runner queue time.
- Cancelled jobs without a runner can have synthetic started_at=created_at:
  their pending lifetime is NOT execution. Partial reruns can carry old successful
  jobs with started_at earlier than created_at; exclude those from attempt timing.
- Summed job minutes are resource demand, NOT wall-clock critical-path duration.
  Run-level elapsed statistics use updated_at-created_at and include queueing;
  only successful first attempts are included, so survivorship bias is explicit.

## What changed

| Period/change | Consequence |
| --- | --- |
| v1.6.0–v1.7.0 | PR CI: one shared root producer and four no-build shards, final Style plus Secret Scan. Sentry and ad-hoc release candidates were separate main workflows; Tip and stable builds remained independent. PR type-check timing was report-only/incremental, main clean/enforcing. |
| October 31, #1575/#1576 | Main qualification retained rather than coalesced; every PR, main and merge-group candidate required Sentry/privacy plus universal release-mode package/MCP smoke. All candidates clean/enforcing. Immutable candidate and attempt provenance introduced; partial reruns intentionally refused. |
| November 2, #1588 | Removed duplicate automatic standalone main Sentry/release-candidate builds. A sensible reduction, but universal packaging still runs on EVERY PR/main integration. |
| November 2, #1605 | Added ARM64 and Intel older-macOS artifact checks to CI and release flows. Artifact portability is valuable; additional queue admissions matter more than their short execution. |
| November 4, #1613 | Integration products deferred until root gates pass; narrower root cache, main-seeded universal cache, Ubuntu Tip setup. Avoids work for rejected candidates; increases isolated successful critical-path depth. No successful new-profile release-cache-hit result observed in this audit. |

Do not revert provenance, coverage, signing or compatibility protections wholesale.
The primary architectural amplification is moving full release qualification onto
every integration candidate and then rebuilding the release separately for Tip.
Actual build growth and cold caches contribute, but do not explain six-hour shard waits.

## Quantitative witnesses (UTC)

| Run / attempt | Observation |
| --- | --- |
| [40441392146 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/40441392146) | v1.7 preparation PR: October 27 02:57:09–03:49:50, 52.7m elapsed. Five macOS jobs, 74.9 execution-minutes, 6.8 summed queue-minutes. Producer queued 2s and executed 31m54s. |
| [40431253440 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/40431253440) | October 27 main: 01:13:05–02:11:49, 58.7m elapsed; 78.9 macOS execution-minutes. |
| [41577853868 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41577853868) | November 3 PR: 04:23:33–13:29:39, 546.1m elapsed; nine macOS jobs, 285.1 execution-minutes. Shard 3 created 06:40:52, started 13:21:25, completed 13:29:26: 400m33s queue, 8m01s execution. Universal packaging step consumed 152m20s. |
| [41629719766 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41629719766) | November 3 main: 11:42:43–17:39:34, 356.8m elapsed; 259.9 macOS execution-minutes. Producer waited 191m09s then ran 47m30s. Last root shard, not compilation, determined final completion. |
| [41587624059 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41587624059) | Root build failed 08:44:26 November 3. Package did not even start until 10:38:50, then occupied a runner through 12:57:39. Style failed at 13:38:04. This wasted work is addressed by #1613 scheduling. Failure itself is not proof of a flaky test. |
| [41564382124 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41564382124) | Cancelled preview: package ran 03:24:00–04:14:34 November 3 (50m34s); root producer never acquired a runner. Do not count its synthetic timestamps as two hours of execution. |
| [41597958477 / 2](https://github.com/repoprompt/repoprompt-ce/actions/runs/41597958477/attempts/2) | Partial rerun: Sentry job created 20:54:21, started 23:12:51, failed 23:13:05 November 3: 138m30s queue for a 14s rejected attempt. Log explicitly says select Re-run all jobs. Carried-over successful jobs have timestamps from attempt 1. |
| [41749586834 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41749586834) | Xcode validation: November 4 00:48:40 created, 03:42:51 started, 03:50:23 completed: 174m11s queue, 7m32s execution. |
| [41749586854 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41749586854) | #1613 final PR workflow: root producer and one shard passed, three shards cancelled while unassigned, products skipped. Not green and not a full after-measurement. |
| [41769391128 / 1](https://github.com/repoprompt/repoprompt-ce/actions/runs/41769391128) | Current-main workflow cancelled with producer unassigned; no after-speedup evidence. |

Reference October 11–27: 603 runs (269 latest-success, 200 failure, 134 cancellation).
222 successful first attempts had elapsed median 54.9m, p90 224.2m.
November 1–3 subset: 87 runs at capture (30 latest-success, 15 failure, 31 cancellation,
11 nonterminal); 20 successful first attempts had elapsed median 380.1m, p90 546.1m.
These unequal-window, mixed-workload descriptive cohorts are NOT a causal benchmark
or failure-rate study. The baseline already had failures and occasional long tails.

## Releases, not just PRs

- [v1.7 draft run 40458990271](https://github.com/repoprompt/repoprompt-ce/actions/runs/40458990271):
  October 27 06:05:04–08:16:13, 131.2m elapsed; 129.2 macOS execution-minutes,
  1.9 summed queue-minutes.
- [v1.8 draft run 41277643268](https://github.com/repoprompt/repoprompt-ce/actions/runs/41277643268):
  November 1 05:37:11–10:12:30, 275.3m elapsed; 136.9 execution-minutes,
  138.3 queue-minutes. Ref validation alone queued 102m46s for 20s execution.
  The release did not suddenly need twice as much compute; most extra time was queueing.
- [October 27 Tip 40437023435](https://github.com/repoprompt/repoprompt-ce/actions/runs/40437023435):
  all publication stages executed; build 115m20s, complete flow 131m07s.
- [November 3 Tip 41678369558](https://github.com/repoprompt/repoprompt-ce/actions/runs/41678369558):
  no runner assigned. Check annotations explicitly report hosted acquisition failure
  and macOS ARM64 capacity constraints. This is independent provider-supply evidence.
- [November 3 Tip 41686375207](https://github.com/repoprompt/repoprompt-ce/actions/runs/41686375207)
  says success, but all release jobs were skipped. Setup was sufficient to conclude
  the candidate was superseded; workflow success is not publication throughput.
- Latest visible public stable: v1.8.1, November 2 14:10:18.
  Latest visible public Tip: tip-b71e6ce6105e, November 2 13:42:18.
- Tip insists on the exact tested current-main SHA and never substitutes newer
  untested main. As CI latency grows, more candidates are obsolete before setup.
  Repeated merges create preserved main work while making older Tip triggers no-ops.
- Stable publication builds secret-free source, validates it, signs/notarizes under
  the release environment, tests the exact signed artifact, then separately promotes
  reviewed checksums. These trust boundaries must remain intact.

## Capacity and system inventory

- Organization API reports Free plan. GitHub documents five concurrent standard
  hosted macOS jobs for that plan, across repository workloads; an override cannot
  be excluded. No repository self-hosted runners; organization runner inventory 403.
  Billing/spend, support overrides, larger-runner allocations and utilization telemetry
  are not established. No credentials or settings were changed to gain visibility.
- Nine macOS jobs per current successful CI candidate: build, four shards, Sentry,
  universal package, two compatibility. Linux jobs: candidate, secret scan, Style.
  Four shards are parallel, fail-fast false; no matrix max-parallel override.
  Producer timeout 75m; shard 30m; Sentry 60m; package 270m; compatibility 15m.
- CI triggers main PR/default events, main pushes, merge_group checks_requested.
  First-attempt PR previews cancel obsolete previews; main, queue and explicit
  reruns retain run-specific groups. No global release-priority reservation exists.
- Tip: successful main CI workflow_run plus manual dispatch; one running/one pending
  automatic channel, non-cancelling; serialized publication. Stable publish/promote
  and release candidate: manual. Stable publication uses protected environment.
- Xcode workspace: selected paths on PR/main, weekly schedule and manual, macos-26,
  no explicit concurrency. Codex updater: manual macOS. Contributor/issue gates: Linux.
- RepoPrompt CE, Tip/stable signing, compatibility, diagnostics, Xcode validation and
  the organization's Homebrew cask updater compete for macOS capacity. Latest cask
  job uses macos-latest. Other inspected sibling repositories returned no Actions
  run records in the bounded latest-run probes.
  This is not organization-wide historical utilization or proof of reserved capacity.
- Source is repoprompt/repoprompt-ce; update feeds use repoprompt-ce-updates and
  repoprompt-ce-tip-updates; cask uses homebrew-repoprompt-ce. Package.swift pins
  upstream and organization Swift forks plus vendor and provider-package dependencies.
- Binary caches preserve checksum-verified SwiftPM artifacts. Old main root snapshots
  occupied 6.39GB each; three caches totaled 14.06GB at capture. Old restores took
  2–3.5m despite root clean builds. #1613 replaces them with exact-policy support seeds.
  New support-cache restore missed in run 41749586854; dependency resolution took
  8m12s vs 47s in the selected older warm run. This is NOT a controlled slowdown proof.
  No new universal seed existed in captured cache inventory. Old-ref reruns still
  execute old workflow/cache policy; merging a fix does not rewrite those runs.
- Conductor coordinates local lanes and per-user heavy admission independently of
  GitHub. Current source auto-sizes 1–4 memory-weighted slots, despite docs/help saying
  default 1; non-module default reservation is 5GiB. Most root builds consume all
  slots; module tests can share. Never bypass these locks or infer live holders from
  stale lock metadata. Local active occupancy was not measured.
- Local entrypoints: focused dev-test/dev-provider-test, dev-lint, ci runner/conductor/
  release selftests, guardrails, explicit pr-ready outgoing-path selection, release
  preflight/artifact, optional live smoke. The pre-change tree had no single documented local fast-check target; the accompanying
  `make check-fast` adds one without replacing full or safety validation.

## Security/settings and Vercel (pre-change live snapshot)

Active Protect main ruleset requires exactly Style from GitHub Actions, one review
and last-push approval, linear history, no deletion/force push. Four listed users
have PR-only bypass. Strict up-to-date status policy is false; no merge_queue rule.
Legacy protection also enforces admins and conversation resolution. Source support
for merge_group does not mean a merge queue has been activated.

No tracked Vercel/Biome/package.json configuration was found in this Swift repo;
current-main checks are GitHub Actions, status list empty, recent deployments use
release/tip-release environments. The supplied Biome/typecheck/migration story is
not verified for this repository. External application/deployment code and Vercel
account settings were not audited. Do not claim absence of an external integration,
or equate deployment success with protection.

## Repair order and tradeoffs

1. **Restore separation of integration and release qualification.** Keep all current
   core/secret/coverage/Sentry/privacy checks blocking Style. Stop universal package
   and older-macOS artifact qualification on every PR/main Style. Preserve mandatory
   exact-artifact checks for Tip/stable and manual candidate flow. This removes three
   macOS jobs per successful integration, including 125–157m package work in inspected
   examples, but that is avoided observed workload, not measured future latency.
   Tradeoff: release-only regressions may merge; publication must still fail closed.
   Version the admission contract rather than accept old complete-profile receipts.
2. **Keep #1613's useful fixes; measure rather than stack speculative optimizations.**
   Preserve failed-candidate short-circuiting, correct cache scope, exact identity,
   Ubuntu eligibility. Release cache benefit remains unmeasured; do not promote
   untrusted cached/PR artifacts into signing to avoid a second build.
3. **Improve operator path.** Document Style versus publishability, full-run reruns,
   focused local checks, queued versus executing state, and a bounded local fast
   command. Do not issue cosmetic pushes/retries to make a queue move.
4. **Next measurement-driven work, not bundled policy guesses:** two-vs-four shards
   (less fan-out but longer isolated latency, no hard release reservation); Linux-only
   pure-script checks (validate portability first); scoped packaging checks for
   release-boundary PRs; exact-provenance partial reruns (never blindly reuse artifacts);
   main coalescing only after preserving every introduced commit's secret-scan range;
   isolate proven flakes with tracked owners and deterministic witnesses, not retries.
5. **If residual saturation remains:** request actual organization limits/usage and
   discuss release-reserved capacity or scheduling as an explicitly approved change.
   GitHub concurrency groups alone do not provide cross-workflow priority/fairness.

Measure first-feedback and final-Style latency, ready-to-start wait by job class,
macOS execution-minutes per candidate, actual Tip/stable publication interval,
rejected/superseded work, cache hits and full-profile rerun frequency. Separate old
and new workflow SHAs, cold/warm caches, PR/main/manual, and assigned/unassigned jobs.

Rollback: restore the previous versioned integration profile and three removed
jobs, without loosening publication gates or server-side rules. Keep evidence of
exact candidate/workflow SHA and do not count cancelled/partial runs as passing.
No before/after improvement from this proposal has yet been measured.

## Maintainer-guidance check

User impact: bounded contributor feedback and flowing releases. Root cause confidence:
confirmed workload amplification and queueing, plus explicit provider capacity errors;
exact organization contention attribution unknown. Authority: workflow DAG, immutable
artifact receipts and live rules, not UI labels. State risk: accidentally publishing an
untested/substituted artifact or accepting stale receipts. Scale risk: per-candidate
universal builds and repeated whole-profile attempts. Scope: rebalance now with approval,
retain correctness/security invariants, measure follow-ups. Validation: behavioral DAG/
profile/coverage tests, actionlint, repository/preflight checks, then exact-head hosted CI;
no local test can prove hosted capacity improvement.

Sources: repository commits and linked runs above;
https://docs.github.com/en/actions/reference/limits and
https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency.

## Reliability incident and recovery

### Observed failure, not a capacity hypothesis

Baseline inspected: main `26ccf4fa8bbe41b9b7cfb95bb8aa9a1afeb6ee83`,
2026-11-04. The recent capacity changes retained all integration obligations,
but their combined state was not validated adequately:

- #1623 consolidated four logical shards onto one worker.
- `test_required_style_retains_core_and_sentry_without_release_builds` still
  asserted the removed `shard: [1, 2, 3, 4]` matrix text.
- That contract was in `conductor-selftest`, but absent from the path-selected
  CI harness used to validate the worker change. #1624 passed on an independent
  baseline. A mechanical merge check did not exercise the combined contracts.

Three fresh runs failed the same assertion in **Run conductor tests**, before
app compilation. Times are UTC, from job metadata and downloaded logs:

| PR / job | Mac job start → finish | Failing step |
|---|---|---|
| [#1619](https://github.com/repoprompt/repoprompt-ce/actions/runs/41834884057/job/126591327513) | 13:05:35 → 13:22:56 | 13:22:13 → 13:22:48 |
| [#1595](https://github.com/repoprompt/repoprompt-ce/actions/runs/41835681343/job/126594026803) | 13:14:13 → 13:32:16 | 13:31:38 → 13:32:10 |
| [#1583](https://github.com/repoprompt/repoprompt-ce/actions/runs/41844822703/job/126625678735) | 14:10:17 → 14:25:53 | 14:25:15 → 14:25:48 |

These three failed Mac jobs consumed **51 minutes of observed job execution**
combined, not queue time or billing, to rediscover a portable contract failure.
Locally, baseline `python3 Scripts/test_modularization_tooling.py` reproduced
exactly one failure out of 31 tests. The repaired suite retains the full four-shard
obligation instead of asserting an obsolete scheduling shape. Running this contract
on Ubuntu before Mac admission avoids allocating Macs for this known defect class.
No hosted latency improvement is claimed from this local reproduction.

Separately, [main CI attempt 3](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833167618/attempts/3)
inherited a successful candidate declaration whose **log** contained attempt 2
(12:59:02). Style received that context at 14:25:56 and rejected it at 14:26:03.
The build, worker and Sentry jobs were skipped by attempt-equality conditions.
The jobs API labelled inherited rows with attempt 3; API row labels alone cannot
establish execution lineage. This is a policy dead end, not evidence of a test flake.

### End-to-end authority and the repair

1. **Local iteration:** `check-fast` now includes the cross-workflow contracts.
   Mandatory commit/push safety still performs secret scans and guardrails;
   `pr-ready` selects additional lanes. None is a substitute for hosted acceptance.
2. **PR/queue/main CI:** portable contracts run in a separate Ubuntu job before
   scarce Mac work. Secret Scan remains dependent only on candidate declaration,
   so a tooling-contract failure cannot suppress a main push's introduced-range scan. Candidate
   identity stays immutable; successful root producers carry their own attempt
   and Swift/Xcode identity. Native partial reruns reuse exact successful ancestors,
   never a guessed/latest artifact. Rebuilding invalidates old worker receipts.
3. **Merge:** exact head/base and final Style still gate acceptance. A change in
   either invalidates prior evidence. No bypass, required-check or ruleset changes.
4. **Release:** unsuccessful main CI blocks automatic Tip eligibility. Successful
   exact-current-main CI may start Tip; signed-artifact, smoke and compatibility
   qualification still gate publication. Stable/manual flows have separate gates.
   No production workflows or release credentials are changed by this repair.
5. **Visibility:** each executing job reports failed step IDs; Style shows upstream
   results and recovery before parsing potentially missing admission output.
   Reports are explanatory, never a second success authority or a flakiness oracle.

### Tradeoffs and acceptance evidence

- Native retry reuse saves successful ancestor work **only when a retry occurs**.
  Missing outputs, expired artifacts and changed Swift/Xcode fail closed and require
  rebuilding. Exact hosted reuse still needs a real GitHub exercise.
- Workflow contracts add a small Ubuntu prerequisite and run locally too. This
  intentionally catches control-plane failures before dependencies/style/Mac work.
  Test failures must describe current invariants, not obsolete YAML formatting.
- Diagnostics add no API permissions, write token, polling service or external
  messages. They cannot run before a runner is assigned or after runner loss, and
  cancellation may suppress even an `always()` step. The lightweight Ubuntu jobs
  have explicit ten-minute deadlines rather than the default six-hour envelope. The Actions timeline and
  read-only queue reporter remain necessary; a missing report is unknown.
- Three Mac jobs, four full logical shards, all tests, per-suite deadlines, clean
  typecheck policy, Sentry/privacy, secret scan and release qualification remain.
  This does not create capacity or prove that long-running product tests are healthy.

Local regression acceptance includes native later-attempt selection, wrong
run/candidate/future attempt rejection, toolchain drift, missing outputs, actual
coverage-CLI acceptance of retried worker receipts and rejection after a rebuild,
and every failed/cancelled/skipped prerequisite blocking Style with diagnostics.
The combined release suite also caught an old shell-text assertion in
`test_manual_candidate_qualifies_exact_archive_without_entering_style`; it now
checks the new gate entrypoint. The existing executable prerequisite test still
rejects every non-success Sentry result.

Run the combined CI harness, conductor/release selftests, guardrails and actionlint,
not only isolated admission tests.

**Hosted acceptance still required:** retain a complete successful PR run, rerun the
root worker, Sentry and Style independently, and verify original producer outputs
and exact coverage survive. Verify a real failed job's ID reaches the aggregate
summary. Do not call the incident permanently solved until those receipts exist.
Main/Tip publication is not a canary for this: use a non-production PR and do not
cancel healthy jobs or alter release/security settings to manufacture a failure.

Measure time-to-Style, allocation delay, execution minutes and recovery cost on
comparable successful runs. Keep failed/cancelled runs separate. Billing, account
runner limits and organization-wide contention are not established by these logs.

### Rollback and remaining visibility boundary

Rollback the producer-reuse change through a reviewed PR and return to the explicit
all-jobs policy if hosted semantics fail. Keep the corrected workflow contract and
early diagnostics. Never remove Style, coverage, secrets or release gates as rollback.
Existing runs retain their original commit's behavior; retrying them cannot install
this fix. Update affected PR branches after integration rather than repeatedly
rerunning deterministic old failures.

`Publish Tip` still skips its setup on unsuccessful CI. CI now explains that blocked
eligibility, but a dedicated Tip-side rejection summary would require a separately
reviewed change to the production workflow. No such change is made here.

Maintainer-guidance check: user impact is blocked feedback/releases; confirmed
causes are the stale contract and attempt equality, not inferred test flakiness.
GitHub job results plus exact producer/coverage identity remain the authority.
No user data or credentials change. Remaining risks are hosted reuse semantics,
runner loss and scarce capacity; local mocks cannot prove those boundaries.
