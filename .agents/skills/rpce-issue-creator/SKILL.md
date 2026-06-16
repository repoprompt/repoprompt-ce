---
name: rpce-issue-creator
description: Draft, deduplicate, review, refine, or file maintainer-friendly GitHub issues for RepoPrompt CE from rough notes, investigation findings, or agent context. Use when a user or agent needs a clear RepoPrompt CE issue draft or explicitly requests issue filing.
---

# RepoPrompt CE Issue Creator

Create concise, actionable issues for `repoprompt/repoprompt-ce`. Remove private or identifying data from source material before using it in a draft. Ask only for missing details that materially affect reproduction, routing, or acceptance.

## Workflow

1. Classify the request as a bug, regression, enhancement, task, docs issue, investigation follow-up, or question.
2. Search open and closed issues in `repoprompt/repoprompt-ce` before drafting. Link likely duplicates; if the report is distinct, state the differing symptom, environment, version, or commit. Do not file blindly.
3. Draft the issue using the content and CE-specific evidence guidance below.
4. Review the complete draft and remove or redact all private and identifying data.
5. Show the user the exact final title, body, and proposed labels. Obtain immediate explicit approval to file; approval to investigate or draft is not approval to create the issue.
6. Only after approval, run `gh issue create --repo repoprompt/repoprompt-ce` with the reviewed payload. Report the URL. Note that issues from unapproved contributors may be auto-closed for maintainer review under `CONTRIBUTING.md`.

## Write Actionable Content

- Use a specific title naming the affected area and observable problem or desired behavior.
- Open with impact and scope, then state expected versus actual behavior.
- Give the smallest deterministic reproduction: starting state, numbered actions or command, frequency, and result.
- Record only relevant environment facts: release or debug app, app version/build or commit, macOS version, architecture, and provider/runtime when material. Do not include environment dumps.
- Include a known-good version, first-bad version, or regression range when available.
- Summarize focused validation and evidence; distinguish confirmed facts from hypotheses.
- Keep scope, non-goals, dependencies, risks, and open questions only when they help maintainers act.
- Write acceptance criteria as observable outcomes, not implementation instructions; include regression coverage when appropriate.

Route the affected surface without guessing a fix:

- Product flow or UI: `Sources/RepoPrompt/Features/<Feature>`
- App lifecycle, launch, or composition: `Sources/RepoPrompt/App`
- Cross-cutting file, process, security, MCP, or platform behavior: `Sources/RepoPrompt/Infrastructure/<Area>`
- CLI-only behavior: `Sources/RepoPromptMCP`
- Shared app/CLI MCP wire contract: `Sources/RepoPromptShared/MCP`
- Provider catalog, codec, or translation behavior: `Packages/RepoPromptAgentProviders`

## Use CE-Specific Evidence

- Distinguish the RepoPrompt CE app and `rpce-cli-debug` from production/non-CE `rp-cli` or `rp-cli-debug`, which may connect to a different app. State which executable and app build reproduced the behavior.
- Prefer coordinated, boundary-specific evidence: focused `make dev-test FILTER=<Suite>` for root logic, `make dev-provider-test` for provider-package behavior, `make dev-swift-build PRODUCT=RepoPrompt|repoprompt-mcp` for build boundaries, and `make dev-smoke` only for live CE app/MCP wiring when an appropriate debug app is already running.
- Use the minimum bounded evidence needed: command plus result, a short redacted excerpt, counts, timings, or hashes. Never paste entire daemon logs, crash dumps, generated diagnostics, or raw command output.
- Treat DEBUG-only MCP diagnostics such as `__repoprompt_debug_diagnostics` and diagnostic `app_settings` as sensitive. Prefer structured bounded snapshots, and do not assume built-in redaction makes raw output publishable.
- Do not enable raw provider logging or launch, relaunch, or stop a visible app merely to draft an issue. If local raw capture is genuinely necessary, require separate approval where repository rules demand it, keep it bounded and owner-only, redact the distilled evidence, and clean up the capture.

## Remove Private Data Before Filing

Before showing a draft or filing an issue, remove or redact:

- PII such as unnecessary names, emails, usernames, or account details
- Credentials, API keys, tokens, cookies, authorization headers, signing data, or secret-bearing arguments
- Private prompts, responses, transcripts, repository/workspace content, filenames, or screenshots
- Absolute home/workspace paths, private hostnames, environment dumps, and identifying session/window/context/run IDs
- Raw provider events, JSONL, traces, full logs, crash reports, daemon job logs, or generated diagnostic artifacts

Replace removed values with clear placeholders such as `<redacted>`, use repository-relative paths, and prefer coarse facts or minimal redacted excerpts. Immediately before asking for filing approval, check the exact title, body, labels, attachments, screenshots, and command payload again for private data. If required evidence cannot be redacted without losing its meaning, stop and ask the user for a publishable summary; do not file.
