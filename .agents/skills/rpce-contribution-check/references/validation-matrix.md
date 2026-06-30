# RepoPrompt CE contribution validation matrix

Use this after the mandatory safety preflight when the touched boundary needs focused, PR-ready, release, or live-app evidence.

## Mandatory safety gates

| Gate | Required command / evidence |
| --- | --- |
| Before every commit | `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` runs whitespace checks, a redacted staged-index secret scan, and `make guardrails`. Rerun after any staging change. |
| Before every push | `.agents/skills/rpce-contribution-check/scripts/preflight.sh push` reruns commit safety, requires a clean working tree, prints the current-branch outgoing range, and runs a redacted outgoing-range secret scan. |

Default `push` is a safety gate. It does not run heavyweight lint, test, provider, conductor, product-build, or full Xcode workspace validation lanes. Run focused commands during iteration, and run `.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready` when a computed-outgoing-range path-selected local PR-ready pass is required.

## Focused and PR-ready evidence

| Changed boundary | Focused / PR-ready evidence |
| --- | --- |
| `Scripts/conductor.py`, conductor/preflight control-plane tests, the contribution preflight script, or `Makefile` conductor wiring | `make conductor-selftest`; included in `pr-ready` for these paths. |
| Hosted app-test CI runner boundary (`.github/workflows/ci.yml`, `Scripts/ci_app_test_runner.py`, `Scripts/test_ci_app_test_runner.py`) | `make ci-app-test-runner-selftest`; included in `pr-ready` for these paths. Hosted CI follow-up is still required for real macOS runner/process behavior. |
| Swift files | `make dev-lint`; included in `pr-ready` for Swift paths. Run `make dev-format` first when formatting mutation is intended. |
| Root app source or root tests | Use the smallest focused `make dev-test FILTER=<Suite>` during iteration. Full `make dev-test` is the PR-ready/full local lane when required and is included in `pr-ready` for `Sources/RepoPrompt/` or `Tests/RepoPromptTests/`. |
| Provider package source or tests | `make dev-provider-test`; included in `pr-ready` for provider-package paths. |
| `Sources/RepoPrompt/**` | `make dev-swift-build PRODUCT=RepoPrompt`; included in `pr-ready` for these paths. |
| `Sources/RepoPromptMCP/**` or `Sources/RepoPromptShared/**` | `make dev-swift-build PRODUCT=repoprompt-mcp`; included in `pr-ready` for these paths. |
| Generated Xcode workspace boundary (`Package.swift`, `Package.resolved`, `Makefile`, `Scripts/generate_xcode_workspace.py`, `Scripts/xcode_developer_workflow.sh`, `.github/workflows/xcode-workspace.yml`) | `make xcode-generator-test` and `make xcode-validate`; included in `pr-ready` for these executable/workflow paths. Changes to `Scripts/test_xcode_workspace_generator.py` run `make xcode-generator-test` only. The dedicated hosted `Xcode Workspace Validation` workflow also runs for PR/main path-filtered changes to this boundary plus `docs/architecture/xcode-workspace.md`; docs-only Xcode architecture changes remain guardrails-only locally unless explicit validation is requested. |
| Packaging, MCP CLI/server, Agent Mode, or running-app-sensitive paths | Record non-disruptive `make dev-smoke` when an already-running CE debug app and installed debug CLI are available; request approval before `make dev-smoke-launch`, `make dev-run`, or relaunching the visible app. |
| Release-sensitive changes | Run explicit release validation such as `make dev-release-preflight`; use `make dev-release-artifact` only when artifact evidence is required. Release lanes are not part of default `push` or `pr-ready`. |
| History rewrite, branch deletion, fork deletion, force-push, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or visible app stop | Obtain explicit user approval immediately before the destructive command; redact secret values from output. |

## Secret hygiene

- Treat obfuscated, encoded, or split credentials as secrets. Do not print their decoded values.
- Use `gitleaks` with `--redact` for materialized staged index blobs and outgoing commits.
- Do not commit local configuration, prompt exports, daemon logs, raw provider traces, or generated diagnostic artifacts unless the repository explicitly allows the exact path.
