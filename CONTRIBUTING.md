# Contributing to RepoPrompt CE

RepoPrompt CE is a community repository. The contribution gate keeps incoming
work manageable and gives maintainers room to review changes carefully.

## Contribution Gate

New issues and pull requests from accounts that are not approved are closed
automatically. Maintainers may reopen worthwhile issues after review.

The gate reads the tracked [`.github/APPROVED_CONTRIBUTORS`](.github/APPROVED_CONTRIBUTORS)
file. The listed people opted in to publishing their GitHub handles. Each entry
has one capability:

- `issue`: issues stay open.
- `pr`: issues and pull requests stay open.

The allowlist does not grant repository access. Invitations and organization
membership are managed separately.

Maintainers may reply `lgtmi` on an issue to approve its author for future
issues, or `lgtm` to approve its author for future issues and pull requests.
Contributors may also propose ordinary reviewed changes to the tracked list.

## Before Submitting A Pull Request

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Do not check raw generated RP outputs into the repo; prompts, reviews,
investigations, analysis, designs, and reference dumps are working artifacts
unless deliberately distilled into durable docs. Local `docs/investigations/*.md`
reports stay unignored so RepoPrompt tooling can read them; do not stage or merge
them unless intentionally requested.

Run the smallest relevant coordinated validation commands from [`AGENTS.md`](AGENTS.md).
At minimum:

```bash
make guardrails
make dev-lint
```

Add focused `make dev-test FILTER=<SuiteName>` coverage for behavior changes.
When changing the Xcode generator, workflow wrapper, or generated scheme
contracts, also run:

```bash
make xcode-generator-test
make xcode-validate
```

Do not change release metadata, signing identities, bundle IDs, Sparkle keys, or
release channels unless a maintainer has explicitly requested it.
