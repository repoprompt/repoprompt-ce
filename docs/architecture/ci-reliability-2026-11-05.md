# CI reliability diagnosis and repair

Review date: 2026-11-04 UTC / 2026-11-05 JST. Historical observations cover
GitHub records available around 16:05–16:20 UTC; subsequent PR status is recorded
separately. This review builds on draft [PR #1628](https://github.com/repoprompt/repoprompt-ce/pull/1628),
including its producer-architecture binding and standard Intel runner changes
through `96b2db89b5104f8b82baa65eb2da5fd1185d5bce`.

**Status:** implementation prepared; complete hosted integration, native partial
reruns, automatic recovery, and publication remain acceptance requirements.
Local portable checks are not proof of those hosted boundaries. The review did
not merge a PR, rerun or cancel existing workflows, change repository protection,
or publish a release.

## Diagnosis

The deterioration is real, but it is not one mysterious flaky build. Several
changes combined to increase Mac demand, reject legitimate native retries, hide
the original failure behind an aggregate check, and discard qualified Tip sources.
There are also independent fixture races and genuine performance failures.
Those categories need different responses.

### The screenshot is an admission-policy dead end

[Main CI run 41833167618](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833167618)
tested source `26ccf4fa8bbe41b9b7cfb95bb8aa9a1afeb6ee83`:

1. Attempt 1's build was cancelled before receiving a runner. Application code
   did not execute in that build job.
2. Attempt 2's [build job 126588000648](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833167618/job/126588000648)
   ran for **14m06s**, then failed a Python workflow contract. The assertion still
   required the literal four-worker matrix `shard: [1, 2, 3, 4]`, although #1623
   had consolidated those logical shards into one worker.
3. Attempt 3 retained the successful candidate output from attempt 2. Strict
   equality between candidate attempt and consumer attempt then skipped the build,
   root tests and products. [Style job 126634646095](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833167618/job/126634646095)
   rejected a failed-jobs-only rerun before explaining the underlying prerequisites.

The red Style row was not evidence of a Swift formatting failure. Neither
repeating that partial retry nor repeatedly retrying the obsolete source can
install a corrected workflow.

### What actually worked around v1.7.0

[v1.7.0](https://github.com/repoprompt/repoprompt-ce/releases/tag/v1.7.0) was published
on October 27 at 08:52:52 UTC, from
`3253f289a69a366b3e55bd28f47d024f932d77a5`.
[CI run 40450235101](https://github.com/repoprompt/repoprompt-ce/actions/runs/40450235101)
also experienced a real test failure:

- The build passed after **41m40s**; shards 1–3 passed.
- [Shard 4](https://github.com/repoprompt/repoprompt-ce/actions/runs/40450235101/job/122023253096)
  failed a performance assertion: 6.7339 seconds exceeded its computed
  6.3055-second limit.
- Attempt 2 retained the successful build and other shards. Only shard 4
  (**7m19s**) and Style needed to run again.
- [Tip run 40456608344](https://github.com/repoprompt/repoprompt-ce/actions/runs/40456608344)
  subsequently succeeded.

The useful historical property was recoverability and reuse. It was not an
absence of performance-sensitive tests.

### Where the regression entered

[PR #1576 / commit c060d222](https://github.com/repoprompt/repoprompt-ce/commit/c060d22235efd73c53371187086fed1e2d022e1d),
October 31 at 12:37:28 UTC, combined three expensive policy changes:

- Main work stopped coalescing: main runs and explicit retries received per-run
  concurrency groups, so obsolete candidates could all compete for Macs.
- Every candidate acquired additional Sentry/privacy and universal release-package
  qualification work.
- Candidate identity and artifact identity were coupled to the consumer's current
  run attempt, intentionally disallowing native partial reruns.

[#1622](https://github.com/repoprompt/repoprompt-ce/commit/65405c7117ea7372c15ef7816b0701e57c920ef0)
subsequently removed duplicate release qualification from integration CI.
[#1623](https://github.com/repoprompt/repoprompt-ce/commit/f715d128c391377b4624dcb7c97680fe3918f338)
consolidated root workers, but left the old contract assertion. PR #1628 repairs
producer identity and adds early contract checking; those repairs are worth
preserving rather than reverting the entire pipeline to an old version.

### Measured deterioration and its limits

The following sample uses GitHub run records with workflow name `CI`, event
`push`, and branch `main`. Elapsed time is `updated_at - created_at`, so it includes
queueing and retries. It is **not billing data**. The later window ends at the
November 4 observation; it is not a complete November 4 day.

| UTC window | Runs | Success | Failure | Cancelled | Median successful elapsed |
| --- | ---: | ---: | ---: | ---: | ---: |
| October 25–28 | 62 | 14 | 1 | 47 | 69.0 min |
| November 2–4 through observation | 33 | 4 | 8 | 21 | 298.0 min |

Many cancellations were deliberate supersession. Counting all cancellations as
broken builds would exaggerate the failure rate. Among noncancelled runs, the
observed outcomes were 14/15 versus 4/12 successful.

[Run 41591529773](https://github.com/repoprompt/repoprompt-ce/actions/runs/41591529773)
illustrates the capacity problem particularly clearly: the build waited
**5h43m59s**, then executed for **54m30s**. Shard 4 waited another **3h11m41s**,
then executed for **17m56s**. The ten-hour run was not a ten-hour compile. Its
317,918,792-byte root archive, about 303 MiB, was downloaded by four workers.

Eight assigned Mac jobs rediscovered the same stale matrix assertion:

| Run / job | Mac job elapsed |
| --- | ---: |
| [41833167618 / 126588000648](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833167618/job/126588000648) | 14:06 |
| [41833003026 / 126588018872](https://github.com/repoprompt/repoprompt-ce/actions/runs/41833003026/job/126588018872) | 17:47 |
| [41834884057 / 126591327513](https://github.com/repoprompt/repoprompt-ce/actions/runs/41834884057/job/126591327513) | 17:21 |
| [41835379718 / 126592958271](https://github.com/repoprompt/repoprompt-ce/actions/runs/41835379718/job/126592958271) | 17:23 |
| [41835681343 / 126594026803](https://github.com/repoprompt/repoprompt-ce/actions/runs/41835681343/job/126594026803) | 18:03 |
| [41844822703 / 126625678735](https://github.com/repoprompt/repoprompt-ce/actions/runs/41844822703/job/126625678735) | 15:36 |
| [41844840531 / 126625707607](https://github.com/repoprompt/repoprompt-ce/actions/runs/41844840531/job/126625707607) | 17:34 |
| [41845790795 / 126629066820](https://github.com/repoprompt/repoprompt-ce/actions/runs/41845790795/job/126629066820) | 17:40 |
| **Total** | **135:30** |

That total is job execution elapsed, excluding queue time. It does not establish
an account's billed minutes, plan, spending cap, or aggregate concurrency.
[GitHub's limits](https://docs.github.com/en/actions/reference/limits) and
[standard hosted-runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
distinguish capacity from billing; standard hosted compute for a public repository
does not justify an inference that a paid-minute allowance was exhausted.

### Tip could be green without publishing anything

[Tip run 41686375207](https://github.com/repoprompt/repoprompt-ce/actions/runs/41686375207)
finished green, but only its resolver executed. The
[resolver log](https://github.com/repoprompt/repoprompt-ce/actions/runs/41686375207/job/126093101308)
rejected tested source `def4f33c` because main had advanced to `16329d2b`. All
publishing jobs were skipped. The newer main candidate then failed CI.

This is a release-starvation mechanism: requiring the passing candidate to equal
the moving branch tip discards useful evidence while providing no guarantee that
the replacement will pass.

Publishing is not universally broken. The
[publisher in run 41810511872](https://github.com/repoprompt/repoprompt-ce/actions/runs/41810511872/job/126598317534)
published and audited `tip-65405c7117ea`, build `42.22.93`, at 13:21:42 UTC on
November 4. Upstream admission, scheduling and recovery are intermittent blockers.

## Repair design

### 1. Keep identity strict while making retries usable

PR #1628's `integration-v3` model separates immutable candidate identity from the
successful root producer's run attempt, architecture, Swift and Xcode identity.
A later consumer can reuse the earlier successful producer. It must still select
that producer's exact same-run artifact and satisfy exact receipt and coverage
checks. Rebuilding the producer invalidates receipts from the old build.

All four logical shards, provider/module checks, secrets, Sentry/privacy, exact
coverage union and required `Style` check remain mandatory. A missing artifact,
unknown output or wrong toolchain never becomes a success.

### 2. Fail cheap checks before requesting a Mac

`Portable Checks` now runs the combined portable CI, conductor and release
selftests, plus the pinned Codex schema check, on Ubuntu 24.04. This removes
duplicated harness work from the Mac producer. The producer waits for both
portable checks and the independent secret scan.

Compiler-dependent repository guardrails stay on Mac, before dependency
restoration/resolution. `ci-macos-selftest` preserves native process supervision,
Apple `plutil` and ICU behavior, the real unsigned-archive rejection test, and
IndexStore library binding. Tests decorated to skip on Linux must still execute
on their supported platform; a cheaper green skip is not equivalent coverage.

The existing local full `conductor-selftest` and `release-selftest` targets retain
their native checks. The selected CI/contribution paths include the new recovery
controller and its regression tests.

### 3. Coalesce pending main stages without dropping secret scans

Whole-workflow main cancellation would suppress introduced-commit-range secret
scans. Instead, first-attempt main builds, root workers and Sentry jobs each have
a separate concurrency group. Each stage preserves its running job and retains
one pending request. A newer pending request replaces the previous pending one.
Every push's independent secret scan can finish.

PR previews continue to supersede obsolete previews. Explicit retries use a
per-run group. Generated Xcode workspace validation gains PR supersession and a
30-minute execution deadline.

[GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
does not promise ancestry order. An older request can arrive late and evict the
current main candidate. The recovery controller handles only the matching
system-annotated current-main eviction, using the retry's independent group.
Ordinary user cancellation is not reversed.

This is deliberately a bounded capacity improvement, not a global scheduler.
Different stages, PRs, releases and other repositories can still contend for the
account's available Mac slots. A single root worker also trades fewer allocations
and downloads for coarser retry cost: retrying that worker reruns its four logical
shards. No unmeasured end-to-end speedup is claimed.

### 4. Recover recognized infrastructure failures within a fixed budget

The new `CI Recovery` workflow runs trusted default-branch code after failed or
cancelled CI. It never checks out PR code with its write-capable token.

| Evidence | Automatic action | Boundary |
| --- | --- | --- |
| Explicit hosted-runner acquisition/provisioning failure annotation | Retry failed jobs and dependents | Zero steps/runner ID alone is insufficient |
| Recognized artifact transport failure in an exact download step | Retry failed jobs | Preserve successful producer evidence |
| Exact named producer artifact missing/expired, or confirmed worker architecture/Swift/Xcode drift | Rebuild the successful root producer and dependents once | Never substitute another run's artifact |
| Current main cancelled by the matching pending-stage concurrency group | Retry that stage and dependents | Require the precise system annotation and fresh main identity |
| Source, lint, test, security, coverage or unclassified failure | Explain and stop | No retry-until-green policy |
| Manual cancellation or superseded candidate | Leave stopped | Do not resurrect unwanted work |

The cap is **three total source-run attempts**, including prior manual attempts,
and **one rebuild of an already-successful root producer**. Rebuild history counts
actual execution timestamps, not copies of retained results across attempts.

Before issuing a request, the controller checks the active workflow ID/path,
source repository, event and attempt, latest branch CI run, and current main or
open same-repository PR. For PRs, the original synthetic merge is proven through
the immutable referenced reusable-workflow SHA and its actual parent commits;
mutable nested PR refs cannot prove which merge was tested. A moved base/head
requires a fresh candidate. Fork and merge-group runs remain outside automatic
recovery.

Startup annotations are read from the job's validated `check_run_url`; a job ID
is not a check-run ID. API evidence is bounded and paginated. Candidate freshness
is rechecked immediately before requesting a retry. Missing evidence, exhausted
budget, API failure or an unconfirmed submission produces an explicit summary.
No successful-check override or external success registry is introduced.

### 5. Select tested Tip sources and make publication outcomes explicit

Automatic Tip setup resolves source eligibility when its rolling queue starts.
It considers the authenticated successful triggering CI event and up to 300 recent
successful main-push CI runs, then selects the newest candidate by pinned
protected-main first-parent ancestry. Completion order is not source order.
The triggering event closes the race where a completed run is not yet visible in
the list API. API errors still fail explicitly.

A tested main ancestor can publish while newer main is untested or red. The exact
source CI run/attempt and a separate protected-main tooling SHA are recorded.
Source checkouts are passed as approved data to trusted tooling. Manual dispatch
keeps its current-main source/tooling identity requirement.

Before requesting a Mac, setup validates existing versioned/latest publication
manifests and skips an already-published source or one covered by a newer
publication. Fresh packaging, signing/notarization, packaged-helper smoke and
dual-architecture older-macOS compatibility remain publication prerequisites.

The final Ubuntu result job reports published, already covered, or blocked
outcomes and every prerequisite. A failed release gate cannot become a green
resolver-only success. The bounded source search is reported; the workflow never
falls back to untested main when qualified evidence is unavailable.

Automatic and explicit manual Tip lanes remain independent. If both admit the
same unpublished source simultaneously, they can both build. The serialized
publisher preserves the first publication and rejects a second build with
different signed bytes. Early deduplication eliminates ordinary sequential
duplicates; it is not an exclusive build reservation across manual and automatic
lanes. This visible conflict is preferable to mutating an immutable publication.

### 6. Preserve release artifacts across native retries

Tip, stable preparation and stable promotion use artifact names containing the
run and the producing attempt. Downstream jobs receive exact successful producer
outputs; they do not construct a new name from their own attempt. Retention is
seven days, and empty artifact names fail before download.
Extending release artifact retention from one day to seven uses more storage.
The benefit is retaining expensive signed bytes through queue delays and failed-job
retries. Observe actual artifact bytes and account storage usage before tuning
that window; this review does not claim a measured net billing reduction.

Stable source resolution now captures the verifier's status before writing its
output. Previously, `echo` could mask failure inside command substitution. A
full SHA is required. Promotion's pure source-admission job moves to Ubuntu.

The publisher's portable file-size helper uses `os.stat`; GNU `stat -f` could emit
non-size output before the old fallback. Release source, signing, ownership,
compatibility and immutable-asset checks remain intact.

Immutable publication is an intentional limit: after a partial draft upload,
retry with the original signed bytes. A full rebuild can produce different
signatures; overwriting an existing immutable asset is not a safe recovery.
If its original seven-day artifact has expired, use a fresh source/tag or an
explicitly reviewed draft-cleanup procedure. This repair does not silently
delete or replace releases.

### 7. Fix demonstrated fixture defects without weakening product checks

The quota single-flight test had a priming race. The service publishes `.loaded`
before clearing its in-flight task, so the measured refresh could join the
priming operation and report zero new reads. The fixture now waits for both
loaded state and no in-flight read before establishing its baseline. It still
requires exactly one read for concurrent refreshes.
The [failure evidence](https://github.com/repoprompt/repoprompt-ce/actions/runs/41589711537/job/125763472737)
was `1` expected versus `0` observed.

The large Claude transcript fixture built a 2,000-frame payload inside a routing
deadline using repeated Data concatenation. It now prepares the fixture before
the routing clock and appends in linear time. All 2,000 frames, delivery/terminal
assertions, and the existing 15-second bounds remain. The
[observed failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/41817296321/job/126552063764)
included burst settling failure and 15.6803 seconds against a 15-second limit.

The [companion projection failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/41646869299/job/126112251760),
2.3275 seconds against two seconds, remains a genuine profiling question. The
limit was not raised and the assertion was not removed. The earlier Python
deadline-fixture stdout race is already repaired in the inspected source.

## Validation and remaining acceptance

Local focused validation passed admission, recovery, diagnostics, workflow
contracts, exact coverage, contribution path selection, and the portable release
suite. Tests execute the actual resolver shell with hermetic inputs as well as
the Python policy functions. Regression cases cover stale candidates, missing
evidence, attempt caps, wrong source origins, artifact output wiring, verifier
failures and publication prerequisite failures.

Final focused counts are 20 admission, 40 recovery, 7 diagnostics, 34 workflow/
modularization, 16 coverage, 4 contribution-path, 21 Tip-selection, and 42
publisher/workflow-admission tests. The full portable release target passed before
the last event-visibility refinement (180 tests with one expected Mac-only skip);
the affected selector and publisher suites were rerun afterward with the final
21/42 counts above. The native counterpart of that skip remains explicitly in
`ci-macos-selftest`.

Actionlint passed all eight affected/relevant workflows with ShellCheck disabled
because it is unavailable locally. The installed actionlint 1.7.12 does not know
the pre-existing GitHub `concurrency.queue: max` feature; only that exact schema
message was ignored. Bash syntax, whitespace checks and a redacted whole-tree
Gitleaks scan also passed. Exact command/results are retained with the review
handoff.

The full local native/hosted gate is **not** claimed:

- This environment lacks Swift, SwiftFormat, SwiftLint, Xcode and Apple's
  signing/runtime tools. `make guardrails` requires real `swift package
  dump-package` and `swiftc` import inspection. Repository commit/push preflight
  cannot pass without those compiler checks; no stub or skip was introduced.
- This container restricts process inspection and Unix datagram sockets. The
  complete conductor/process harness therefore has environment failures; the
  focused portable result does not establish that the entire new Ubuntu job
  succeeds on GitHub.
- Platform-decorated tests have explicit Mac invocations. Their Linux skips do
  not count as native passes.

For the pre-existing PR head `96b2db89`,
[Xcode run 41865373650](https://github.com/repoprompt/repoprompt-ce/actions/runs/41865373650)
succeeded and [CI run 41865373323](https://github.com/repoprompt/repoprompt-ce/actions/runs/41865373323)
had acquired an Intel runner and passed guardrails/hosted harness checks at the
16:37 UTC observation. It was still running. This is evidence that the changed
pool allocated a runner; it does not validate the additional changes in this
review. The earlier ARM allocation failure alone did not establish a billing
cap. Full PR integration on Intel also does not establish full ARM-native test
coverage; production ARM/Intel release qualification remains separate.

Before treating the incident as resolved, retain these exact-revision results:

1. A complete PR pass: Portable Checks, secret scan, compiler/style/provider/module
   gates, all four root shards, Sentry/privacy, and final Style.
2. A real native worker partial rerun that reuses the successful producer and
   preserves exact coverage; Sentry-only and Style-only reuse must also succeed.
3. A controlled infrastructure/evidence failure exercising the trusted recovery
   workflow, its single rebuild boundary and its terminal summary. This workflow
   becomes active on the default branch; PR unit tests cannot prove that lifecycle.
   Confirm subsequent completed events permit recovery up to the configured cap
   and that a recovered main success triggers ordinary Tip qualification.
4. Fresh main-push admission and Tip publication through signed artifact smoke,
   compatibility and final publication audit. Confirm duplicate/newer-covered
   events stop before a Mac build, and a tested ancestor remains eligible after
   main advances.
5. Observe queue time, assigned Mac execution, retry cost and real publication
   cadence separately over several ordinary merges. Do not substitute green
   workflow count for released Tips.

Do not use an old successful main run as a casual retry canary: a successful
main CI rerun can trigger Tip qualification. Old commits retain their old workflow
policy; affected branches need the repaired source and a fresh run.

## Rollback and operating boundaries

If automatic recovery misclassifies evidence, disable/revert its workflow through
a reviewed change; ordinary producer-bound native retries remain available.
If pending-stage coalescing misbehaves, revert those three stage groups while
retaining independent scans and early portable gates. If Tip selection needs
rollback, preserve its exact producer artifacts and final status reporting.

The existing Intel routing commit is independently reversible. No automatic
architecture fallback is introduced: compiled artifacts remain bound to their
producer architecture/toolchain. Do not increase account concurrency, buy larger
runners, weaken performance limits, skip secret scanning or remove Style as a
substitute for fixing the observed failure.

See [admission](ci-admission.md), [testing](../testing.md) and
[releasing](../releasing.md) for the maintained operational procedures.
