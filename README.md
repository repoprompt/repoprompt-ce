# RepoPrompt CE

[![CI](https://github.com/repoprompt/repoprompt-ce/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/repoprompt/repoprompt-ce/actions/workflows/ci.yml?query=branch%3Amain)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-black)

**A free, open-source native macOS app and agent orchestrator for context engineering.**

RepoPrompt CE helps coding agents understand your codebase before they act. It
assembles focused, reviewable context from files, CodeMaps, repository
structure, and Git diffs, then hands that context to AI tools and CLI agents.

RepoPrompt CE also builds an agent harness around its bundled MCP server.
Connect MCP-compatible clients and CLI agents to search repositories, inspect
files, curate context, run agent sessions, and orchestrate work through a shared
native macOS interface.

## Get Started

Choose one of these local setup paths. You do not need to open Xcode.

### Build and launch locally

For development and quick evaluation, double-click
[`Launch RepoPrompt CE.command`](Launch%20RepoPrompt%20CE.command) in Finder.

The launcher builds RepoPrompt CE from source, opens the debug app, and keeps a
small terminal window available for rebuild, status, and stop controls.

| Key | Action                                      |
| --- | ------------------------------------------- |
| `r` | Rebuild and relaunch                        |
| `s` | Show app status                             |
| `x` | Stop the app                                |
| `q` | Close the launcher without stopping the app |

### Install a local production build

For a release-mode app under `/Applications`, double-click
[`Install RepoPrompt CE Local Production.command`](Install%20RepoPrompt%20CE%20Local%20Production.command)
in Finder.

The installer builds RepoPrompt CE from source and replaces any existing
`/Applications/RepoPrompt CE.app` using a dedicated self-signed certificate
trusted only on your Mac. macOS may ask you to approve the certificate.

The resulting app is local-only. It is not notarized and should not be copied to
another Mac or redistributed.

### Source-build requirements

- macOS 26 or later
- Xcode 26, or matching Command Line Tools with the macOS 26 SDK

## Features

- **Context engineering**: Build dense, reviewable prompts with the files and
  repository details an AI model actually needs.
- **Codebase orientation**: Combine file trees, selected file contents, line
  slices, CodeMaps, and Git diffs.
- **Context Builder**: Let an agent explore the repository, identify relevant
  files, and curate context within a token budget.
- **Agent orchestration**: Run and coordinate CLI-backed coding agents from the
  native macOS app.
- **MCP server and CLI integration**: Connect external MCP-compatible tools and
  CLI agents to RepoPrompt CE's repository context and agent harness.
- **Multi-root workspaces**: Work across related repositories, packages, and
  documentation folders in one workspace.
- **Reviewable handoffs**: Inspect and refine selected context before sending it
  to another model or agent.

## About the Community Edition

RepoPrompt CE is the free, open-source community edition of RepoPrompt. It is a
native macOS workspace for context engineering, agent orchestration, and local
development.

Maintainers track release signing, Sparkle metadata, dependency pins, and
third-party notices in
[`docs/open-source-readiness.md`](docs/open-source-readiness.md).

## Contributor Documentation

- [`AGENTS.md`](AGENTS.md): coordinated builds, tests, launches, live MCP
  checks, source placement, and contribution preflight
- [`CONTRIBUTING.md`](CONTRIBUTING.md): contribution policy and pull request
  steps
- [`docs/architecture/source-layout.md`](docs/architecture/source-layout.md):
  source ownership and placement rules
- [`docs/architecture/provider-plugins.md`](docs/architecture/provider-plugins.md):
  Agent Mode provider architecture
- [`docs/releasing.md`](docs/releasing.md): release-candidate and publishing
  workflows
- [`docs/open-source-readiness.md`](docs/open-source-readiness.md): public
  readiness inventory

## License

RepoPrompt CE is licensed under [Apache-2.0](LICENSE).
