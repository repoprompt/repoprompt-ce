# Guidance sources and interpretation notes

This is a curated evidence ledger, not a transcript. It records durable principles from user-authorized Discord review while minimizing private-conversation detail. Public channel locators are included where available. Private DM material is summarized rather than quoted for redistribution.

Historical guidance never overrides current repository instructions, code, tests, product behavior, or a newer explicit maintainer decision.

## Durable principles

| Principle | Evidence locator | Interpretation |
| --- | --- | --- |
| Fix the cause of stalls, not the symptom. | Repo Prompt Discord, `#🤝│contributors`, 2026-07-10 12:05 and 12:07. [Channel](https://discord.com/channels/1262487703744675901/1510443780434563265) | An unexplained retry or patch adds complexity and can hide the real state-machine failure. Investigate first. |
| Do not ship silent state loss. | Repo Prompt Discord discussion on Classic-to-CE settings migration, 2026-07-10; private maintainer conversation on agent/Oracle settings after crashes, 2026-07-03. | Decode, migration, crash, and fallback paths deserve explicit preservation checks and user-visible handling. |
| Keep async agent work visible. | Private maintainer conversation, 2026-07-10 09:59–10:15, on sub-agent tool-card visualization for new reasoning modes. | If a mode performs background work but the card surface shows nothing useful, the feature is operationally incomplete. |
| Stage optional scope when a smaller complete path exists. | Private maintainer conversation, 2026-07-10 10:06–10:15. | A higher tier could follow later because the existing sub-agent path already served users; completeness matters more than rushing every tier. |
| Inspect upstream protocol source. | Private maintainer conversation, 2026-07-10 10:18. | Adding the current Codex CLI source to the workspace helps verify app-server calls and avoids guessing at integration behavior. |
| Defaults balance cost and quality. | Private maintainer conversation, 2026-07-03 20:41–20:49. | Model availability and maintainer personal use do not automatically define the default. Make the least aggressive justified default change. |
| Measure end-to-end latency. | Repo Prompt Discord, `#🤝│contributors`, 2026-07-01 05:59–06:03. [Channel](https://discord.com/channels/1262487703744675901/1510443780434563265) | Instrument the production queue/path and measure impact on tool execution, including load amplification; helper-local timing is insufficient. |
| Prefer incremental computation and coalesced publication. | Repo Prompt Discord, `#🤝│contributors`, 2026-07-01 00:22. [Channel](https://discord.com/channels/1262487703744675901/1510443780434563265) | Expensive estimates and projections should use deltas and caches. Off-main-actor data requires explicit sync points and coalesced UI binding updates. |
| Explore simpler structural tooling without collapsing subsystem responsibilities. | Private maintainer conversation, 2026-07-09 09:20–09:30, on CodeMaps, an external structural-core repository, and `ast-grep`. | The proposed replacement was explicitly tentative. Current CodeMaps already use Tree-sitter AST queries plus substantial post-processing and downstream artifact infrastructure, so evaluate exactly which layer a new engine could simplify before proposing migration. |
| Split mixed issues and keep hypotheses labeled. | Private maintainer conversation, 2026-07-06 09:30–09:38. | A deterministic routing trigger, a freshness wedge, and possible missed-resume paths belonged in separate tracks; static leads were not treated as proven bugs. |
| Validate large changes intensely. | Repo Prompt Discord, `#🤝│contributors`, 2026-06-30 21:12. [Channel](https://discord.com/channels/1262487703744675901/1510443780434563265) | A strong design does not reduce the validation burden of a large change. |
| Treat development tooling as product infrastructure for contributors. | Private maintainer conversation, 2026-07-03 20:57–20:59, on packaging, Xcode latency, and conductor. | Coordinated, agent-usable tooling is part of making contributions safe and efficient. |
| Expose task-appropriate tool profiles. | Repo Prompt Discord, 2026-06-26 03:08. | Raw tools are not always the best interface; a narrower agent-tool surface can be more usable and safer outside Agent Mode. |

## Time-sensitive guidance

Model names, reasoning tiers, role assignments, token economics, CLI versions, and release sequencing are time-sensitive. Examples observed in July 2026 included GPT-5.5/5.6 role recommendations, Max/Ultra availability, and Claude Fable availability. Use these only as evidence for the durable principles below:

- roles should match model behavior;
- expensive capability should be used intentionally;
- defaults should preserve a cost-quality balance;
- availability should not silently change recommendations;
- provider metadata and RPCE presentation must agree.

Before acting on model guidance, inspect the current app-server catalog, provider adapter, recommendation engine, migrations, and focused tests.

## Interpretation guardrails

- Distinguish a direct maintainer statement from analysis he forwarded or endorsed.
- Preserve qualifiers such as "I think," "optional," and "worth investigating."
- Do not convert a bug lead into a prescribed implementation without reproduction and code evidence.
- Do not expose private DM excerpts in public issues. Publish only redacted, independently verified technical facts.
- If two pieces of guidance conflict, prefer the more recent one that is supported by current code and product behavior.
