# RepoPrompt CE contribution validation matrix

Use this after the scripted preflight when the touched boundary needs focused evidence.

| Changed boundary | Minimum focused evidence before push |
| --- | --- |
| Any contribution | `git diff --check`, `make guardrails`, staged-index secret scan before commit, outgoing-range secret scan before push |
| `Scripts/conductor.py`, conductor tests, or `Makefile` conductor wiring | `make conductor-selftest` |
| Swift files | `make dev-lint` |
| Root app source or root tests | `make dev-test` or the smallest focused `make dev-test FILTER=<Suite>` during iteration; run full `make dev-test` before push |
| Provider package source or tests | `make dev-provider-test` |
| `Sources/RepoPrompt/**` | `make dev-swift-build PRODUCT=RepoPrompt` |
| `Sources/RepoPromptMCP/**` or `Sources/RepoPromptShared/**` | `make dev-swift-build PRODUCT=repoprompt-mcp` |
| `Sources/RepoPromptCore/**`, `Sources/RepoPromptCoreMacOS/**`, or `Sources/RepoPromptPOSIXSupport/**` | Build the affected target(s) and run the smallest focused Core test target(s) |
| `Sources/RepoPromptHeadless/**` or headless packaging/install/smoke scripts | `make dev-swift-build PRODUCT=repoprompt-headless` plus the non-visible headless smoke lane when available |
| Packaging, MCP CLI/server, Agent Mode, or running-app-sensitive paths | Record non-disruptive `make dev-smoke`; request approval before `make dev-smoke-launch`, `make dev-run`, or relaunching the visible app |
| History rewrite, branch deletion, fork deletion, force-push, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or visible app stop | Obtain explicit user approval immediately before the destructive command; redact secret values from output |

## Secret hygiene

- Treat obfuscated, encoded, or split credentials as secrets. Do not print their decoded values.
- Use `gitleaks` with `--redact` for materialized staged index blobs and outgoing commits.
- Do not commit local configuration, prompt exports, daemon logs, raw provider traces, or generated diagnostic artifacts unless the repository explicitly allows the exact path.
