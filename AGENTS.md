# Agent Notes

This is a Swift Package macOS app for RepoPrompt CE.

Prefer the coordinated developer daemon (`make dev-*`, see "Developer daemon / coordinated validation" below) for builds, runs, and tests. It runs every job through a lane-serialized queue so concurrent agents do not build, launch, or test over each other, and it returns a ticket for each job so long builds can be detached and checked on later instead of blocking. The plain `make` / `swift` / `./Scripts` commands shown below are the uncoordinated fallback for when the daemon is unavailable.

## Contribution preflight

Before every commit or push, read and run the repository-local `$rpce-contribution-check` skill:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

Stage only the intended changes, then use `commit` mode before creating a commit; rerun it after any staging change, including partial-staging updates. Use `push` mode after committing but before pushing the intended current branch. These default modes are mandatory safety gates: they enforce redacted staged-index and outgoing-range secret scanning, repository guardrails, and clean push boundaries. Default `push` does not run heavyweight lint/test/build lanes; use the explicit `pr-ready` lane when you need the computed-outgoing-range path-selected local PR-ready pass:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
```

Focused validation and release validation remain explicit; use the validation matrix plus commands such as `make dev-release-preflight` / `make dev-release-artifact` when the changed boundary requires them. Obtain explicit user approval immediately before any force-push, history rewrite, branch deletion, fork deletion, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app.

Local `docs/investigations/*.md` reports are intentionally left unignored so RepoPrompt tooling can read them. Do not stage or merge these local investigation artifacts unless intentionally requested.

## Run

```bash
make doctor     # verify Swift/Xcode command line tool setup, SDK, signing diagnostics, SwiftUI probe, and debug CLI status
make dev-run    # coordinated build, package, stop existing RepoPrompt, and launch the debug app
```

`make dev-run` routes through the developer daemon (see "Developer daemon / coordinated validation") and remains the ordinary FIFO coordinated launch path. For a user-directed newest lifecycle action, use `./conductor app relaunch`; the Finder launcher uses that operation when `python3` is available. The uncoordinated equivalents are `make run` or `./Scripts/run.sh`.

Debug packaging may auto-detect an Apple Development signing identity for a valid local app signature, but auto-detected debug signing still uses ephemeral in-memory secure storage to avoid macOS Keychain prompts. Set an explicit `SIGN_IDENTITY="Apple Development: ..."` to opt in to persistent debug Keychain storage; `DEBUG_SECURE_STORAGE_BACKEND=keychain` is also supported for explicit debug storage opt-in when the signed app has a TeamIdentifier. If no stable identity is available, set `ALLOW_ADHOC_SIGNING=1` to build an ad-hoc debug app; ad-hoc debug builds use ephemeral in-memory secure storage, so API keys and secure permission changes do not persist across launches. Release packaging requires `SIGN_IDENTITY` and continues to use real Keychain storage.

## Debug

Package without launching:

```bash
make dev-build                  # coordinated debug package (preferred)
# uncoordinated equivalents:
make build
./Scripts/package_app.sh debug
```

Use verbose shell tracing when packaging fails or hangs:

```bash
VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log
```

The debug app bundle is created through:

```text
.build/debug/RepoPrompt.app
```

SwiftPM’s architecture-specific build output is usually under:

```text
.build/arm64-apple-macosx/debug/
```

## Generated Xcode workspace

The repository-owned workspace is a disposable developer convenience under
`.build/xcode`; `Package.swift`, conductor, and `Scripts/package_app.sh` remain
authoritative.

```bash
make xcode                  # generate and open
make xcode-generate         # generate without opening
make xcode-generator-test   # deterministic generator contract tests (default CI)
make xcode-validate         # explicit full validation with xcodebuild -list
make xcode-clean            # remove generated workspace metadata
```

Default CI runs `make xcode-generator-test`; full `make xcode-validate` is explicit and runs through local `pr-ready` for Xcode workspace boundary changes or the dedicated `Xcode Workspace Validation` workflow.

Xcode 26.3 exposes the native `RepoPrompt` and `repoprompt-mcp` product schemes.
Use `RepoPrompt CE App` and `RepoPrompt CE MCP` for conductor-coordinated debug
products. `RepoPrompt CE Tests` delegates to conductor because `RepoPromptMCP`
is executable-only and cannot back a native Xcode unit-test dependency. Do not
edit or commit `.build/xcode`, use these schemes for release/archive work, or
assume canceling Xcode cancels a queued conductor job; inspect
`./conductor job list` after cancellation. See
[`docs/architecture/xcode-workspace.md`](docs/architecture/xcode-workspace.md).

## Debug CLI / MCP

Use the CE-specific debug CLI when testing this app. The production `rp-cli` / `rp-cli-debug` connection is only an analogue and may talk to the non-CE app.

Install or inspect the debug CLI:

```bash
make debug-cli-status
make install-debug-cli     # packages the debug app, then installs /usr/local/bin/rpce-cli-debug
./Scripts/doctor.sh --install-debug-cli
```

The installer links:

```text
/usr/local/bin/rpce-cli-debug
  -> ~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug
  -> ~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp
```

If `/usr/local/bin` needs administrator privileges, run the install target from an interactive terminal so `sudo` can prompt, or install the CLI from Settings → MCP → CLI Tools. Without the PATH link, use the direct fallback:

```bash
"$HOME/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug" -e 'windows'
```

Live CE MCP smoke flow:

```bash
make run
rpce-cli-debug -e 'windows'
rpce-cli-debug -w 1 -e 'workspace switch repoprompt-ce'
rpce-cli-debug -w 1 -e 'tree --type roots'
rpce-cli-debug -w 1 -c agent_manage -j '{"op":"list_agents","roles_only":true}'
```

Then use `agent_run` for end-to-end Agent Mode behavior:

```bash
rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","session_name":"CE debug CLI smoke","message":"Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.","detach":true}'
rpce-cli-debug -w 1 -c agent_run -j '{"op":"wait","session_id":"<session_id>","timeout":120}'
```

Before live Agent Mode or Claude investigations, enable debug-only diagnostics through the CE debug app's MCP `app_settings` surface:

```bash
rpce-cli-debug -w 1 -c app_settings -j '{"op":"list","group":"agent_mode","detailed":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_logging_enabled","value":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_log_file_path","value":"/tmp/repoprompt-ce-claude-raw-events"}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.perf_diagnostics_enabled","value":true}'
```

These settings are intentionally DEBUG-only. If a key is unavailable, confirm `rpce-cli-debug --version` is resolving to the current CE debug build before falling back to lower-level defaults.

## Developer daemon / coordinated validation

Prefer the developer daemon as the default way to build, run, and validate. Two properties are the whole reason it exists — and the reason to reach for it instead of a bare `swift build` / `swift test`:

- **Lane-serialized job queue** — every job claims named lanes (`build`, `debugArtifact`, `liveApp`, `release`, `style`); the daemon runs jobs that share a lane one at a time while letting unrelated lanes proceed concurrently. That serial queue is what stops multiple agents from building, launching, or running style tooling over each other and corrupting `.build` or the live app.
- **Tickets + async jobs** — every job gets a ticket and can run detached (`--async`). Fire a build, keep working, and query or wait on it later (`job status` / `job wait`) instead of blocking on a long compile. Jobs survive reconnects and are reusable by `--request-key`.

`conductor` is repo-internal developer tooling for this checkout; the daemon auto-starts on first use.

Happy path — daemon aliases:

```bash
make dev-status
make dev-build
make dev-swift-build PRODUCT=repoprompt-mcp         # focused product build (PRODUCT=RepoPrompt|repoprompt-mcp|all, default all)
make dev-run
make dev-test                                       # full coordinated test suite
make dev-test FILTER=WorkspaceFileContextStoreTests # focused coordinated test run
make dev-test-list                                  # coordinated authoritative root XCTest method list
make dev-provider-test                              # RepoPromptAgentProviders package tests (FILTER= also supported)
make dev-provider-test-list                         # coordinated authoritative provider XCTest method list
make dev-smoke          # non-disruptive: requires an already-running CE debug app and installed debug CLI
make dev-smoke-launch   # builds/launches the debug app, then runs the smoke flow
make dev-format-check   # non-mutating coordinated SwiftFormat check
make dev-lint           # non-mutating coordinated format-check + SwiftLint strict
make dev-format         # mutates first-party Swift files; run only when intended
make dev-format-tools-status
make dev-check-format-tools
make dev-install-format-tools
```

Lane detail: the mutating `format` daemon job also claims `build` (it rewrites files the compiler reads); non-mutating `format-check` and `lint` use only `style`; read-only `format-tools-status` is intentionally unlaned so it never queues behind a build.

Daemon lanes coordinate daemon-submitted operations only; they do not freeze source files against editor changes, direct commands, or edits from another agent. Avoid starting a coordinated build or relaunch while another actor is editing the same checkout. If compilation fails because an input file was modified during the build, wait for edits/builds to settle before retrying; for stable compiler errors, fix them and retry. A compile/rebuild failure is not lifecycle supersession.

Async/reconnectable jobs (so work survives reconnects and is shareable by key):

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

`--request-key` is idempotent: a matching queued/running job is reused instead of enqueuing a duplicate. Track and reconnect to jobs with `./conductor job list`, `job status`, `job wait`, and `job cancel`, each addressable by ticket or `--request-key`. `make dev-stop-app` / `./conductor app stop` is an overriding interactive stop: it cancels older active or queued `liveApp` operations before confirming the app is stopped. `make dev-daemon-stop` stops the daemon itself.

Daemon output defaults are intentionally concise for agent use: synchronous `dev-*` commands and `job wait` print progress highlights, a terminal summary, and the full log path instead of replaying raw build/test/style output. Full raw logs are still preserved under the daemon jobs directory and can be rendered with `--full-log`, for example `./conductor build --full-log` or `./conductor job wait --request-key debug-package --full-log`. `--verbose` is separate: it passes `VERBOSE=1` to delegated scripts where supported so more detail is captured in the stored log, but it does not by itself replay raw output. On failures, inspect the concise highlights first, then open the printed log path or rerun/wait with `--full-log` if the summary is insufficient.

Behavior notes:

- `make dev-run` (daemon `run`) still delegates to the debug launch flow and stops only the running process whose resolved executable matches the target CE debug app, same as `make run`; it remains FIFO and does not supersede older lifecycle work.
- `./conductor app relaunch` is the overriding interactive relaunch used by the Finder launcher; like `app stop`, it can cancel older active or queued `liveApp` work. It builds/packages before replacing the visible app, so a failure before lifecycle work begins does not itself stop or reopen an already-running app.
- Do not assume an in-flight `run`, `smoke`, or diagnostics job will complete if another operator issues `app stop` or interactive `app relaunch`.
- `make dev-smoke` is the non-disruptive live-only check: it assumes the CE debug app is already running and the debug CLI is installed/resolvable.
- `make dev-smoke-launch` (or `./conductor smoke --launch`) builds/packages and launches the debug app before smoke validation.
- `./conductor smoke --agent-run` is opt-in, for when provider credentials and model access are available.
- Style checks (`make dev-format-check`, `make dev-lint`) are non-mutating and do not auto-install tools; `make dev-install-format-tools` is the explicit install path.
- Do not run `make dev-format` unless formatting mutation is intended. If a format job is canceled after starting, inspect `git diff` and rerun format or restore files as needed.

Direct / uncoordinated commands — use only when the daemon is unavailable but required tooling, including `python3`, remains available:

```bash
make build
make run
make test
```

These do not claim daemon lanes or lifecycle supersession, so when multiple agents are active they can build, launch, or run style tooling over each other; a direct launch may reopen the app after a coordinated stop. The Finder launcher requires `python3` and does not provide an uncoordinated no-Python fallback because safe lifecycle actions require exact debug-executable identity checks. Prefer the `dev-*` aliases when the daemon is available. The manual `rpce-cli-debug` commands above remain valid for direct live MCP validation.

## Source placement rules

See `docs/architecture/source-layout.md` for the full ownership map and documented exceptions, and `docs/architecture/provider-plugins.md` for the Agent Mode provider plugin seam (Claude-compatible package, bridge/adapter layout, "add a new provider" recipe). In short:

- Product-flow code goes under `Sources/RepoPrompt/Features/<FeatureName>`.
- App lifecycle, launch/configuration, command, and composition-root wiring stays under `Sources/RepoPrompt/App`.
- Cross-cutting service/platform substrate goes under `Sources/RepoPrompt/Infrastructure/<Area>`.
- App-wide notification names and root app views/view models belong under `Sources/RepoPrompt/App`.
- Bridging-header-sensitive support stays under `Sources/RepoPrompt/Support` unless `Package.swift` is updated in the same change.
- Reusable UI, diffing, regex, networking, process, security, and utility substrate should use the narrowest `Sources/RepoPrompt/Infrastructure/<Area>` owner.
- App-integrated diagnostics belong under `Sources/RepoPrompt/Features/Diagnostics` and need a documented entry point/purpose.
- App/CLI protocol code shared by both products belongs under `Sources/RepoPromptShared`.
- Test doubles, fixtures, parser inputs, sample projects, and XCTest-only helpers belong under `Tests/RepoPromptTests`, not `Sources/RepoPrompt`.
- Do not recreate legacy top-level `Views`, `ViewModels`, `Services`, `Models`, `Utils`, or `Shared` buckets.
- Do not put directories named `Tests`, `TestSupport`, or `Fixtures` under `Sources/RepoPrompt`.
- Keep `MCPControlMessages.swift` single-sourced in `Sources/RepoPromptShared/MCP`.

## Swift style workflow

For Swift edits, run the formatter before handoff. Prefer the coordinated daemon alias so the mutating job is serialized with other daemon work:

```bash
make dev-format
# uncoordinated equivalent:
make format
```

Run the combined style check before handoff when style tooling is relevant or Swift files changed:

```bash
make dev-lint
# uncoordinated equivalent:
make lint
```

For a non-mutating formatter-only check, use `make dev-format-check` (or uncoordinated `make format-check`).

If SwiftFormat or SwiftLint is missing, install them through the repo entrypoint:

```bash
make install-format-tools
# or inspect first:
make format-tools-status
# daemon equivalents:
make dev-install-format-tools
make dev-format-tools-status
```

`make lint` and `make dev-lint` run `format-check` followed by `swiftlint lint --strict`. Do not perform a full repository formatting baseline unless the task explicitly asks for it; do not run `make dev-format` unless formatting mutation is intended.

## Test

Prefer the coordinated daemon so concurrent agents do not test over each other:

```bash
make dev-test                                        # full coordinated suite
make dev-test FILTER=WorkspaceFileContextStoreTests   # focused coordinated run
```

Focused validation commands commonly used for this tree (all daemon-coordinated):

```bash
make dev-format-check
make dev-lint
make dev-test FILTER=CodexIntegrationConfigurationTests
make dev-test FILTER=WorkspaceFileContextStoreTests
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-provider-test
make guardrails
make doctor
make dev-build
```

Run the smallest relevant daemon build/test command above to validate a change. If the change affects packaging, the MCP server, the MCP CLI, Agent Mode, or any feature that depends on the running app, follow it with the live CE MCP smoke flow above.

Direct `swift test --filter <name>` and `swift build --product <name>` still work and produce the same result, but they are uncoordinated — use them only when the daemon is unavailable (for example, no `python3`), and avoid them when other agents may be building.

Use `make dev-run` (or `make run`) only when it is safe to stop any existing RepoPrompt instance and launch the local debug app.

### XCTest optimization inventory and timing

See [`docs/testing.md`](docs/testing.md) for the contributor workflow, exact XCTest IDs, surgical contract-ledger maintenance, scenario accounting, and handoff checklist. Routine executable adds, renames, consolidations, and removals require the affected focused test, authoritative list, and `verify-ledger`; never regenerate or overwrite the curated ledger.

Optimization/performance campaigns additionally require append-only inventory, baseline, focused, and full-root artifacts plus updates to `prompt-exports/optimize-test-suite-runs.md`. The primary metric is warm local root conductor execution time, provider timing remains separate, and diagnostic/wake-probe runs are invalid timing samples retained only as lifecycle evidence.

## Cleanup

```bash
make clean    # removes .build
```
