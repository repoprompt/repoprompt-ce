# CI test gate contract

`CI` uses seven macOS jobs total: one **Build and Static Gates** job, four
**Test Root Shard (No Build)** jobs, and the secret-free Sentry/privacy and
release-mode package/MCP smoke jobs. The exact required check **Style** runs last
on Linux. It depends on the candidate declaration, shared job, all shards,
Secret Scan, and both integration-product jobs; every prerequisite must succeed
(failed, skipped, or cancelled is not success).
The final gate prints those prerequisite results in its job summary so an
upstream test or infrastructure failure is not mistaken for a formatting error.
All former style/static/provider/import/index gates remain blocking. Compiler
warning timing uses the same clean, enforcing protocol on PRs, merge groups,
and main, with unchanged budgets and retained success/failure measurements.
See [integration admission](ci-admission.md) for profile/provenance, rerun policy,
and the explicit gated queue/ruleset rollout; workflow deployment alone does not
activate repository settings.

The shared job also runs every app-free owning module test from
`Scripts/modularization/modules.json` sequentially on its warm VM. These are no
longer post-merge-only jobs. A module test failure or exhausted dependency fetch
therefore blocks the existing required Style check before merge. Sentry-enabled
build/privacy checks now also gate Style through the secret-free product workflow.
CI (main) and Release Candidate remain supplemental workflows with independent
scheduling. Only obsolete first-attempt PR previews supersede one another in CI;
queue/main profile runs retain their evidence. There are no test/build retries
or continue-on-error.

## Evidence and coverage authority

On main `7d9cecd236d19e94e244fdca9d1a3ea49352fa1e`, CI run `36864362834` was green.
Its downloaded build listing has **4,039 unique tests**, from all **10 root test
targets**. Deterministic shard assignments are **1,010 / 1,010 / 1,010 / 1,009**.
The separate provider package's test target is not a root-package target and
continues to run through the provider-package gate.

Reproduction commands (download artifacts outside the checkout):

```sh
gh run download 36864362834 --repo repoprompt/repoprompt-ce --name root-build-36864362834 --dir /tmp/root-ci-evidence
gzip -dc /tmp/root-ci-evidence/root-build.tar.gz | tar -xOf - .build/modularization/ci-test-list.txt > /tmp/root-ci-evidence/tests.txt
wc -l /tmp/root-ci-evidence/tests.txt
# 4039
```

Historical **executed** totals cannot be recovered from this green run: full
conductor logs were VM-local and success logs were not uploaded. Summarized
console output repeats and truncates XCTest summaries; summing it is not valid.
A green exit status alone did not prove that all 4,039 methods ran. This change
makes the comparison reproducible for subsequent runs, not retroactively proven.

For the reported main-only failure:

```sh
gh api --allow-escape-sequences repos/repoprompt/repoprompt-ce/actions/jobs/110376188880/logs
# error: failed downloading .../9.17.1/Sentry-Dynamic.xcframework.zip ... badResponseStatusCode(504)
# error: failed downloading .../9.17.1/SentryObjC-Static.xcframework.zip ... badResponseStatusCode(504)
# Result: failed with exit code 1
```

That was an infrastructure/download failure in SwiftPM, before the
Instrumentation tests ran, not a failing Instrumentation assertion.

The build captures `swift test list --skip-build` and the evaluated
`swift package dump-package` test-target inventory. Every test target must have
listed tests; malformed/empty/duplicate identities fail closed. The inventory
is bound to the manifest SHA alongside existing build/index/test-source
attestations. Swift Testing remains explicitly rejected by root shard build and
artifact validation until it has an authoritative runner.

Every suite requires a zero process exit, a terminal XCTest success/count,
**executed == assigned**, and exact completed-identity multiplicities. Zero,
partial, duplicate, wrong-identity, crashed, and early-exit results cannot
publish a success receipt. XCTest skips count as executed by XCTest, but are
recorded separately as skipped, not passed. CI filtered Sentry runs and module
XCTest executions apply the same count/identity checks; developer no-match
semantics remain unchanged.

Each assigned suite runs once in its own process and sandbox. After a suite
fails, the shard attempts the remaining suites and reports all failures. Any
failure keeps the shard red and prevents a success receipt; this is diagnostic
coverage, not a test retry or permission to ignore an assertion.

`shard-execution-*` artifacts retain full raw suite logs and schema-v1 JSON
receipts for seven days. `expected-coverage-*` retains the built listing and
target inventory independently. Final Style recomputes the deterministic
partition, checks exactly one current-listing receipt per shard, verifies each
assignment/execution, and requires the disjoint union to equal the full listing
and every target to be represented. Missing artifacts or receipts fail closed.
Hosted products and receipts additionally bind candidate/run/attempt/producer,
and artifact names include the attempt. Use **Re-run all jobs**: v1 rejects partial
reruns rather than trusting earlier producers. There are no filters on root shards.
`root-build-*` also lasts seven days, so its lifetime matches those receipts.
After artifact expiry, rerun the build as well as the shards; a shard-only rerun
cannot reconstruct its attested executable.

## Download resilience and limits

Binary caches contain `.build/artifacts`, `.build/swiftbuild/artifacts`, provider
artifacts, and SwiftPM's global binary archive cache. Keys include runner OS/arch
and Package.resolved hashes; no broad fallback restores binaries across pins.
Existing source/compiled caches remain intact. SwiftPM remains responsible for
binary checksums and workspace state; no partial-download cache is saved on
failure.

Root, owning-module scratch, provider, and Sentry package resolution is explicit
before package-consuming checks. Each gets at most three five-minute attempts,
with 10s/20s backoff. Each attempt owns a private process session. Timeout or
nonzero exit terminates all remaining process groups in that session before
retry: Swift's Git children can create groups different from the launcher.
Process inventory and cleanup are bounded and fail closed if ownership cannot
be checked or live attempt processes remain. Existing lockfiles are enforced;
the dependency-free provider has none.
Exhaustion is labeled infrastructure failure and remains red. Builds and tests
are never retried to hide deterministic failures.

Remaining limits: caches and retries cannot guarantee GitHub/Sentry availability;
skipped tests are visible exceptions, not proof their assertions ran; raw-log/receipt
parsing is XCTest-specific and intentionally fails closed if its output format
changes. Sentry and packaging failures still require maintainer triage, now before
admission as well as in supplemental main workflows. The complete profile increases
the macOS runner budget from five to seven jobs; it does not eliminate transport
failures or timing variance.

See the [October 23 reliability audit](ci-reliability-2026-10-23.md) for the
historical failure census, same-commit retry evidence, repairs, and unresolved
boundaries.
