# Concurrency migration validation

Use the coordinated developer daemon from `AGENTS.md`. Do not bypass a queued global heavy slot with direct `swift` or `xcodebuild` commands.

## Baseline

```bash
make doctor
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-test
make dev-provider-test
```

Record conductor ticket and log paths in the migration inventory.

## Per diagnostic batch

Root app/product:

```bash
make dev-swift-build PRODUCT=RepoPrompt
make dev-test FILTER=<AffectedSuite>
```

MCP:

```bash
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-test FILTER=<AffectedSuite>
```

Provider package:

```bash
make dev-provider-test FILTER=<AffectedSuite>
```

Choose only affected products and suites. A focused test should observe a durable cancellation, ordering, lifetime, exactly-once completion, actor-publication, or interoperability contract.

## Phase boundary

For Swift changes:

```bash
make dev-format
make dev-lint
make dev-test
make dev-provider-test
make guardrails
```

Add `make dev-build` when packaging or assembled behavior is affected. Add the documented live CE MCP smoke flow only for MCP, Agent Mode, CLI, or running-app behavior. Launching or relaunching the visible app requires explicit user approval.

When test executables change, follow `docs/testing.md`, run the authoritative test list, and verify the curated ledger.

## Language-mode acceptance gate

Before changing a target or package from `.v5` to `.v6`:

- the active-toolchain probe has verified target-local `-swift-version` flags and generated-workspace behavior, or the change explicitly uses the package-wide fallback;
- every target included in the language-mode change compiles with staged checks;
- focused behavioral tests pass;
- public API and sendability changes are reviewed;
- new escape hatches have written invariants and audit/removal conditions;
- all affected package tests and product builds pass through conductor.

## Skill-only validation

```bash
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" \
  .agents/skills/rpce-swift-6-concurrency-migration
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" \
  .agents/skills/rpce-swift-concurrency-fix
make guardrails
```

Before committing, stage only intended files and run `$rpce-contribution-check` exactly as documented.
