# Agent Notes

This is a Swift Package macOS app for RepoPrompt CE.

Prefer the coordinated developer daemon (`make dev-*`, see "Developer daemon / coordinated validation" below) for builds, runs, and tests. It runs every job through a lane-serialized queue so concurrent agents do not build, launch, or test over each other, and it returns a ticket for each job so long builds can be detached and checked on later instead of blocking. The plain `make` / `swift` / `./Scripts` commands shown below are the uncoordinated fallback for when the daemon is unavailable.

## Contribution preflight

Before every commit or push, read and run the repository-local `$rpce-contribution-check` skill:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

Stage only the intended changes, then use `commit` mode before creating a commit; rerun it after any staging change, including partial-staging updates. Use `push` mode after committing but before pushing the intended current branch. The skill enforces redacted staged-index and outgoing-range secret scanning, repository guardrails, clean push boundaries, and the applicable coordinated validation lanes. Obtain explicit user approval immediately before any force-push, history rewrite, branch deletion, fork deletion, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app.

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

## Debug CLI / MCP

Use the CE-specific debug CLI when testing this app. The production `rp-cli` / `rp-cli-debug` connection is only an analogue and may talk to the non-CE app. `rpce-cli[-debug]` is the **app proxy** command family: it talks to the running app through the bundled `repoprompt-mcp` helper. Use `rpce-headless[-debug]` for the standalone direct-stdio host instead.

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

## Headless CLI / MCP

`rpce-headless[-debug]` is the standalone direct-stdio MCP host. It does **not** launch `RepoPrompt.app`, does not connect to the app-proxy socket, and uses separate headless state and secure storage:

```text
~/Library/Application Support/RepoPrompt CE/Headless/
```

Package, install, inspect, and smoke the debug standalone host with:

```bash
make package-headless                    # stages HeadlessTools/Debug/repoprompt-headless
make headless-debug-status
make install-debug-headless              # installs /usr/local/bin/rpce-headless-debug when writable/sudo is available
make headless-smoke                      # direct stdio initialize/tools/list/read/search/permission/shutdown smoke

# coordinated equivalents:
make dev-package-headless
make dev-headless-debug-status
make dev-install-debug-headless
make dev-headless-smoke
```

Managed links are intentionally separate from the app proxy:

```text
/usr/local/bin/rpce-headless-debug
  -> ~/Library/Application Support/RepoPrompt CE/repoprompt_headless_debug
  -> ~/Library/Application Support/RepoPrompt CE/HeadlessTools/Debug/repoprompt-headless

/usr/local/bin/rpce-headless
  -> ~/Library/Application Support/RepoPrompt CE/repoprompt_headless
  -> ~/Library/Application Support/RepoPrompt CE/HeadlessTools/Release/repoprompt-headless
```

Standalone usage starts fail-closed until roots are configured:

```bash
rpce-headless-debug --state-dir /tmp/rpce-headless-demo config roots add /path/to/repo --name Repo
rpce-headless-debug --state-dir /tmp/rpce-headless-demo doctor
rpce-headless-debug --state-dir /tmp/rpce-headless-demo serve
```

Do not use `rpce-cli[-debug]` as evidence for standalone behavior; it validates the app-bundled proxy. Do not use `rpce-headless[-debug]` as evidence for live app/window/Agent Mode behavior; the first standalone profile is read-oriented and omits app-only, write, VCS, oracle, Context Builder, Agent Mode, and settings tools.

## Developer daemon / coordinated validation

Prefer the developer daemon as the default way to build, run, and validate. Two properties are the whole reason it exists — and the reason to reach for it instead of a bare `swift build` / `swift test`:

- **Lane-serialized job queue** — every job claims named lanes (`build`, `debugArtifact`, `headlessArtifact`, `headlessSmoke`, `liveApp`, `release`, `style`); the daemon runs jobs that share a lane one at a time while letting unrelated lanes proceed concurrently. That serial queue is what stops multiple agents from building, packaging headless tools, launching, or running style tooling over each other and corrupting `.build`, managed artifacts, or the live app.
- **Tickets + async jobs** — every job gets a ticket and can run detached (`--async`). Fire a build, keep working, and query or wait on it later (`job status` / `job wait`) instead of blocking on a long compile. Jobs survive reconnects and are reusable by `--request-key`.

`conductor` is repo-internal developer tooling for this checkout; the daemon auto-starts on first use.

Happy path — daemon aliases:

```bash
make dev-status
make dev-build
make dev-swift-build PRODUCT=repoprompt-mcp         # focused product build (PRODUCT=RepoPrompt|repoprompt-mcp|repoprompt-headless|all, default all)
make dev-run
make dev-test                                       # full coordinated test suite
make dev-test FILTER=WorkspaceFileContextStoreTests # focused coordinated test run
make dev-provider-test                              # RepoPromptAgentProviders package tests (FILTER= also supported)
make dev-smoke          # non-disruptive: requires an already-running CE debug app and installed debug CLI
make dev-smoke-launch   # builds/launches the debug app, then runs the smoke flow
make dev-headless-smoke  # packages repoprompt-headless and runs direct-stdio smoke without app launch
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

- `make dev-run` (daemon `run`) still delegates to the debug launch flow and stops any existing `RepoPrompt`, same as `make run`; it remains FIFO and does not supersede older lifecycle work.
- `./conductor app relaunch` is the overriding interactive relaunch used by the Finder launcher; like `app stop`, it can cancel older active or queued `liveApp` work. It builds/packages before replacing the visible app, so a failure before lifecycle work begins does not itself stop or reopen an already-running app.
- Do not assume an in-flight `run`, `smoke`, or diagnostics job will complete if another operator issues `app stop` or interactive `app relaunch`.
- `make dev-smoke` is the non-disruptive live-only check: it assumes the CE debug app is already running and the debug CLI is installed/resolvable.
- `make dev-smoke-launch` (or `./conductor smoke --launch`) builds/packages and launches the debug app before smoke validation.
- `./conductor smoke --agent-run` is opt-in, for when provider credentials and model access are available.
- `make dev-headless-smoke` / `./conductor headless-smoke` packages `repoprompt-headless` and runs only the standalone direct-stdio smoke; it does not claim `liveApp` and must not be used as app-proxy evidence.
- Style checks (`make dev-format-check`, `make dev-lint`) are non-mutating and do not auto-install tools; `make dev-install-format-tools` is the explicit install path.
- Do not run `make dev-format` unless formatting mutation is intended. If a format job is canceled after starting, inspect `git diff` and rerun format or restore files as needed.

Direct / uncoordinated commands — use only when the daemon is unavailable (for example, no `python3`):

```bash
make build
make run
make test
```

These do not claim daemon lanes or lifecycle supersession, so when multiple agents are active they can build, launch, or run style tooling over each other; a direct launch may reopen the app after a coordinated stop. The Finder launcher also falls back to this direct behavior when `python3` is unavailable, with process-only status/stop controls. Prefer the `dev-*` aliases when the daemon is available. The manual `rpce-cli-debug` commands above remain valid for direct live MCP validation.

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
make dev-swift-build PRODUCT=repoprompt-headless
make dev-headless-smoke
make dev-provider-test
make guardrails
make doctor
make dev-build
```

Run the smallest relevant daemon build/test command above to validate a change. If the change affects standalone headless packaging or safe read-oriented tools, run `make dev-headless-smoke`. If the change affects app packaging, the app-proxy MCP server, the app-proxy MCP CLI, Agent Mode, or any feature that depends on the running app, follow it with the live CE MCP smoke flow above.

Direct `swift test --filter <name>` and `swift build --product <name>` still work and produce the same result, but they are uncoordinated — use them only when the daemon is unavailable (for example, no `python3`), and avoid them when other agents may be building.

Use `make dev-run` (or `make run`) only when it is safe to stop any existing RepoPrompt instance and launch the local debug app.

## Cleanup

```bash
make clean    # removes .build
```
