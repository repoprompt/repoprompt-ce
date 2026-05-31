# RepoPrompt CE

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-black)

**The open-source macOS Context IDE for AI coding agents.**

RepoPrompt CE helps you assemble, inspect, and hand off rich codebase context.
Pick the right files across one or more repositories, summarize project
structure and Git history, and package it all into a dense, reviewable prompt
for ChatGPT, Claude, Codex, Cursor, and other AI coding tools — or hand that
context straight to agents through the bundled MCP server and CLI.

> **Heads up:** RepoPrompt CE is built largely *with* and *for* AI coding
> agents. This README is written for people getting started; the deeper
> day-to-day development workflow lives in [`AGENTS.md`](AGENTS.md) and is
> geared toward agents.

## Features

- **Curate context** — Build focused, reviewable context for an AI model from
  one or more repositories.
- **Combine everything** — Merge selected files, project-structure maps,
  function/type CodeMaps, and Git diffs into a single prompt.
- **Discover automatically** — Run Context Builder to find relevant code and
  produce an optimized prompt for you.
- **Think it through** — Plan, review, and ask follow-up questions in built-in
  chat, including an Oracle flow for second opinions.
- **Run agents** — Drive longer sessions in Agent Mode with supported
  CLI-backed providers.
- **Connect your tools** — Let external MCP clients search, inspect, and select
  repository context from your own setup.

## Quick Start

RepoPrompt CE currently runs as a local source build — you do not need to open
Xcode.

**Requirements**

- macOS 14 (Sonoma) or later
- Xcode 26, or the matching Command Line Tools with the macOS 26 SDK

**Run the app**

1. Double-click [`Launch RepoPrompt CE.command`](Launch%20RepoPrompt%20CE.command)
   in Finder. The launcher builds and opens RepoPrompt CE for you.
2. Keep the small launcher terminal open while you use the app.

**Launcher controls**

| Key | Action                                      |
| --- | ------------------------------------------- |
| `r` | Rebuild and relaunch                        |
| `s` | Show app status                             |
| `x` | Stop the app                                |
| `q` | Close the launcher without stopping the app |

## About the Community Edition

RepoPrompt CE is the open-source community edition of RepoPrompt, originally a
paid macOS app. It removes paid activation flows and license keys while keeping
the core prompt, copy, chat, CodeMap, Agent Mode, and custom-provider features
available without paid license gates.

Maintainers track release signing, Sparkle metadata, dependency pins, and
third-party notices in
[`docs/open-source-readiness.md`](docs/open-source-readiness.md).

## Documentation

The detailed development workflow is split across focused docs — most are
oriented toward contributors and agents:

- [`AGENTS.md`](AGENTS.md) — start here for coordinated builds, tests, launches,
  live MCP checks, source placement, and contribution preflight.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution policy and pull request
  steps.
- [`docs/architecture/source-layout.md`](docs/architecture/source-layout.md) —
  source ownership and placement rules.
- [`docs/architecture/provider-plugins.md`](docs/architecture/provider-plugins.md)
  — Agent Mode provider architecture.
- [`docs/releasing.md`](docs/releasing.md) — release-candidate and publishing
  workflows.
- [`docs/open-source-readiness.md`](docs/open-source-readiness.md) — public
  readiness inventory.

## License

RepoPrompt CE is licensed under [Apache-2.0](LICENSE).
