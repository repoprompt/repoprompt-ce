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
| Packaging, MCP CLI/server, Agent Mode, or running-app-sensitive paths | Record non-disruptive `make dev-smoke`; request approval before `make dev-smoke-launch`, `make dev-run`, or relaunching the visible app |
| History rewrite, branch deletion, fork deletion, force-push, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or visible app stop | Obtain explicit user approval immediately before the destructive command; redact secret values from output |

## Secret hygiene

- Treat obfuscated, encoded, or split credentials as secrets. Do not print their decoded values.
- Use `gitleaks` with `--redact` for materialized staged index blobs and outgoing commits.
- Revoke or rotate any exposed credentials even after rewriting history.
- Remember that deleted branches, forks, cached commit views, pull requests, and collaborator clones may retain old objects. Follow GitHub Support cleanup guidance when direct SHA access remains.
- Do not commit local configuration, prompt exports, daemon logs, raw provider traces, or generated diagnostic artifacts unless the repository explicitly allows the exact path.
