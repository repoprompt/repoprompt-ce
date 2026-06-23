# Testing RepoPrompt CE

Use this guide for contributor-facing XCTest changes. Follow `AGENTS.md` for coordinated daemon use, style checks, and lifecycle approvals. Use `$rpce-test-quality` when deciding whether coverage is worth adding, retaining, consolidating, or removing.

## Quality gate before adding a test

Add a test only when all four answers are concrete:

1. **Contract:** What current behavior must remain true?
2. **Plausible defect:** What realistic regression would violate it, and what is the impact?
3. **Lowest faithful layer:** Can deterministic core or provider-package coverage reproduce the risk, or is root SwiftPM integration actually required?
4. **Observable oracle:** What exact output, state, error, side effect, cleanup, wire format, or bounded performance result distinguishes broken from correct behavior?

Search existing direct and outcome-level coverage first. Prefer a test that fails against known-bad behavior. Do not add invocation-only, no-crash, non-nil-only, source-shape, symbol-presence, constant-restatement, arbitrary-sleep, or coverage-driven tests unless that fact is itself the contract and no stronger oracle exists.

## Add a root or provider XCTest

- **Root target:** place app-integrated and root-package tests under `Tests/RepoPromptTests` and validate with `make dev-test`.
- **Provider target:** place provider protocol, codec, translation, launch-argument, or model-mapping tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests` and validate with `make dev-provider-test`.
- Keep one coherent contract per method. Labeled tables are appropriate when cases differ only by input, boundary, or expected outcome.
- Control time, randomness, environment, resources, ordering, and concurrency. Prefer gates, clocks, or continuations over sleeps, and verify meaningful cleanup or ownership.

Focused daemon-coordinated examples:

```bash
make dev-test FILTER=RepoPromptTests.ExampleTests
make dev-test FILTER=RepoPromptTests.ExampleTests/testBehavior
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests/testBehavior
```

Use the narrowest relevant filter, then broaden only for the affected boundary.

## Authoritative executable IDs

Never derive the executable census from source text or a stale build. Use:

```bash
make dev-test-list
make dev-provider-test-list
```

Listed XCTest IDs have these shapes:

```text
RepoPromptTests.<Suite>/testMethod
RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod
```

The curated ledger prefixes the target:

```text
root/RepoPromptTests.<Suite>/testMethod
provider/RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod
```

Treat these strings as exact, case-sensitive identifiers.

## Maintain the contract ledger surgically

Every executable add, rename, consolidation, or removal requires an atomic, surgical update to `Scripts/Fixtures/test-suite-contract-ledger.tsv`. Never regenerate or overwrite the curated ledger. In particular, do not point `inventory --force` at it.

The TSV header order is fixed. Every live row carries identity/location fields (`method_id`, `target`, `file`, `suite`, `method`, `domain`, `layer`), contract fields (`primary_contract_id`, `secondary_contract_tags`, `validation_class`, `scenario_count`, `fixture_ids`, `observable_oracle`, `failure_risk`), cost/ownership fields (`runtime_seconds`, `resource_cost_tags`, `shared_state_tags`, `lifecycle_owner`), and disposition fields (`current_disposition`, `replacement_method_id`, `preserved_scenario_delta`, `notes`).

For every new or touched row:

- use reviewed, specific contract, oracle, risk, validation-class, and lifecycle values rather than `unreviewed`;
- set optional fixture/resource/shared-state tags when applicable and leave them blank only when none apply;
- use `current_disposition=retain` for a new independent test or a reviewed retained test;
- use `current_disposition=consolidated_replacement` for a live method replacing multiple old methods;
- do not introduce `retain_pending_review`; it is initial-scaffold debt;
- keep `replacement_method_id` blank on live rows because stale removed rows cannot remain in an exact-ID ledger;
- use `preserved_scenario_delta=0` when scenarios are preserved, including table consolidation; justify any nonzero delta in `notes` and the handoff.

### Scenario count

`scenario_count` is the number of distinct input, boundary, outcome, fixture, or lifecycle scenarios protected by the method. It is **not** the assertion count. Consolidating methods into a table lowers executable method count without lowering scenario count unless coverage is deliberately removed.

### Atomic rename, consolidation, and removal workflow

1. Before editing, capture the authoritative target list, the exact old IDs, and scenario totals.
2. Change the XCTest declarations and ledger rows in the same patch.
3. **Rename:** replace the old live row with the new exact ID and record `old ID -> new ID` in `notes` and the handoff.
4. **Consolidate:** delete every obsolete row, add the live replacement row(s), set each replacement's `scenario_count` to the preserved scenario total, and enumerate every exact old ID in `notes`. Record the complete `old IDs -> new ID` mapping in the handoff.
5. **Remove without replacement:** delete the stale row and record `old ID -> removed` plus the duplicate, obsolete/non-contractual, or intentionally-unprotected rationale in the handoff. Campaign removals also go in the append-only scoreboard.
6. Re-list, recount, and verify. No obsolete ID may remain, and no new ID may be absent.

## Verify exact-ID reconciliation

Run:

```bash
python3 Scripts/test_suite_optimizer.py verify-ledger \
  --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv
```

This command validates the exact header schema, duplicate ledger IDs, and equality between live root/provider executable IDs and ledger IDs. It **does not** validate scenario totals, contract metadata completeness, disposition correctness, replacement mappings, or the truth of any descriptive field. Review those manually.

## Summarize scenario totals

Run this before and after a consolidation. Set `SUITES` to a comma-separated list of affected fully qualified suites. Save both outputs and report affected-suite and repository target totals.

```bash
SUITES='RepoPromptTests.ExampleTests' python3 - <<'PY'
import csv, os
from collections import Counter

path = "Scripts/Fixtures/test-suite-contract-ledger.tsv"
wanted = {s for s in os.environ.get("SUITES", "").split(",") if s}
by_target, by_suite = Counter(), Counter()
with open(path, encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        count = int(row["scenario_count"])
        by_target[row["target"]] += count
        by_suite[(row["target"], row["suite"])] += count
for target in sorted(by_target):
    print(f"target\t{target}\t{by_target[target]}")
print(f"repository\ttotal\t{sum(by_target.values())}")
for (target, suite), count in sorted(by_suite.items()):
    if not wanted or suite in wanted:
        print(f"suite\t{target}\t{suite}\t{count}")
PY
```

For consolidations, a zero repository and affected-suite scenario delta is the default acceptance criterion. Any intentional delta requires explicit contract-level justification.

## Evidence tiers

### Ordinary test changes

At minimum, provide:

1. the focused root or provider test command and result;
2. the affected target's authoritative list command and result;
3. the `verify-ledger` command and result;
4. required style/guardrail validation from `AGENTS.md` when applicable.

Ordinary additions, fixes, renames, and removals do not need timing artifacts merely because the harness exists.

### Optimization or performance campaigns

In addition to ordinary evidence, create new append-only inventory, baseline, focused, and full-root artifacts and append the result to `prompt-exports/optimize-test-suite-runs.md`. Never rewrite earlier artifacts or scoreboard history.

Collect 3–5 comparable normal timing samples per measured series. Root and provider timings remain separate. Use a fresh temporary generated ledger path when creating the append-only inventory artifact; never use the curated ledger as inventory output:

```bash
label=example-campaign
inventory="prompt-exports/test-suite-inventory-${label}.json"
baseline="prompt-exports/test-suite-baseline-root-${label}.json"
tmpdir="$(mktemp -d)"
python3 Scripts/test_suite_optimizer.py inventory \
  --ledger "$tmpdir/generated-ledger.tsv" \
  --output "$inventory"
rm -rf "$tmpdir"

python3 Scripts/test_suite_optimizer.py baseline \
  --target root \
  --samples 5 \
  --label "$label" \
  --inventory "$inventory" \
  --scoreboard prompt-exports/optimize-test-suite-runs.md \
  --output "$baseline"
```

Normal timing samples must not enable XCTest stall diagnostics or wake probes. Diagnostic/wake-probe runs are invalid timing samples and may be retained only as separate lifecycle evidence. The scoreboard must report method, contract, and scenario deltas; exact replacement/removal mappings; comparable sample counts; focused/full-root outcomes; and artifact paths.

## Live Agent Mode file-tool performance diagnostic

`Scripts/benchmark_agent_mode_file_tools.py` measures paired `file_search` and `read_file` calls from exactly two concurrent Explore sessions: the normal workspace root and a linked worktree. It requires an already-running RepoPrompt CE DEBUG app and never launches, stops, or relaunches the app.

```bash
python3 Scripts/benchmark_agent_mode_file_tools.py \
  --window-id 1 \
  --marker debugDiagnosticsToolName \
  --path Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift
```

By default the driver creates a detached temporary worktree and removes it only when it remains clean and both sessions are terminal; pass `--worktree /absolute/path` to use and preserve an existing linked worktree from the same Git common directory. The manifest records the benchmark worktree's SHA and dirty state. Each run writes a private (`0700`), non-overwriting directory under `/tmp/rpce-agent-file-tools/v1/`; use `--output-root` to override it. Artifacts include provenance, raw CLI calls and agent logs, capture/runtime snapshots, `samples.ndjson`, and `summary.json`, and may contain sensitive workspace snippets, so review them before sharing. Samples and exact workload counts/order come from DEBUG capture timelines (`Received` through the `event_completion` `MainActorExited`); start/wait binding metadata independently proves local-versus-worktree route provenance, while compacted agent logs validate only surfaced call arguments and the final response. Latency is report-only and has no arbitrary failure threshold. Harness, tool-count, nonempty-marker, read-success, and cleanup invariants are enforced.

Offline replay performs no CLI, model, or app calls and accepts either a checked-in fixture or a prior artifact directory:

```bash
python3 Scripts/benchmark_agent_mode_file_tools.py \
  --replay Scripts/Fixtures/agent-mode-file-tools/v1/paired-success
```

The checked-in success and negative fixtures are privacy-scrubbed subsets derived from real paired captures. They retain relevant event/stage timing shapes but contain no raw agent prose, user paths, UUIDs, or raw logs.

Pure harness validation:

```bash
python3 -m py_compile Scripts/benchmark_agent_mode_file_tools.py Scripts/test_agent_mode_file_tools_benchmark.py
python3 Scripts/test_agent_mode_file_tools_benchmark.py
```

## Handoff checklist

- Protected contract, plausible defect, chosen layer, and observable oracle.
- Added/renamed/consolidated/removed exact IDs, including complete `old -> new/removed` mappings.
- Surgical ledger update confirmed; curated ledger was not regenerated or overwritten.
- `scenario_count` rationale and before/after affected-suite plus root/provider/repository totals for consolidations.
- Exact focused test, list, ledger verification, style, and guardrail commands with exit results.
- For campaigns only: append-only inventory/baseline/focused/root artifact paths, scoreboard entry, sample validity, and timing comparison.
- Any coverage deliberately omitted, removed, moved to diagnostics, or replaced by a guardrail, with justification.
