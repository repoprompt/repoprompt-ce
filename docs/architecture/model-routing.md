# Model Routing Architecture

Current as of 2026-09-19.

## Status

RepoPrompt CE contains a backend-neutral routing framework, app-global Settings and Agent Mode integration, and a bundled Jev adapter. After a TypeSafe key is verified, the persistent `Router` pill can enable routing across sessions. While enabled, routing applies to each new user-created Agent Mode session and each RepoPrompt-managed subagent start. Existing provider sessions, continuations, and steering retain their established target.

## Authority boundary

The host framework owns:

- durable enablement, backend selection, optional per-scope provider requirements, and custom guidance;
- candidate construction from a router-owned quality/cost frontier and live provider catalogs;
- complete executable target identity: provider, model, reasoning effort, and normalized ACP parameters;
- the privacy-bounded semantic request;
- exact request ownership, cancellation, normalized outcome validation, and eventual selection-and-submit transaction.

A backend adapter owns:

- backend identity and display metadata;
- credential/configuration readiness;
- wire encoding, transport, and strict response decoding;
- its versioned selection policy.

Adapters receive the exact task text, optional user-authored routing guidance, routing scope, opaque candidate keys, candidate provider/model/effort descriptions, dated capability and API-list-price evidence, and fixed utility-tier rubrics. They do not receive workspace/repository names, paths, file contents, selections, diffs, transcripts, system prompts, tools, permission state, downstream credentials, or provider session identity. They never invoke downstream providers.

`AgentTaskRouterRegistry` is an internal compile-time composition seam, not a dynamic plug-in ABI. Unknown persisted backend identifiers are preserved but resolve unavailable; the registry never substitutes another backend.

## Durable configuration

`scalarPreferences.modelRouter` is an optional group introduced in schema v9 and extended in schema v10:

```text
enabled
selectedBackendRawValue
candidateRoleRawValues
allowedProviderRawValues
primaryProviderRawValue
subagentProviderRawValue
customInstructions
```

Absence resolves disabled. The optional primary and subagent provider fields are hard constraints for their scopes; when unset, every supported connected provider participates. Custom guidance is trimmed, limited to 1,000 characters and 4,096 UTF-8 bytes, and sent to the routing backend with each request as an explicit preference. Known-setting edits preserve unknown nonblank backend, role, and provider raw values for forward/rollback compatibility. Secrets never enter this document.

`candidateRoleRawValues` and `allowedProviderRawValues` are retained only for schema and rollback compatibility with the earlier preset-based implementation. They no longer affect candidate construction. Manual Agent Models settings are authoritative only when Router is off or an already-established session continues.

## Jev adapter

The bundled adapter uses TypeSafe's documented HTTP surface directly; there is no Swift SDK:

- `GET https://api.typesafe.ai/v1/models` validates an account from a supported Jev alias/family entry (`name`); the pinned version need not appear in that alias list;
- `POST https://api.typesafe.ai/v1/systemone` sends a map containing one `route` choice question and always pins evaluation to `jev-1.13.0`;
- Bearer authentication;
- one request, five-second outer deadline, no RepoPrompt-layer retry;
- explicit 401/403, 422, 429, and 529 classification;
- no request/response-body logging.

`JevRoutingResponseInterpreter` strictly validates returned evaluator identity, the single mapped `route` choice answer, exact opaque-key coverage, finite ranged probabilities, distribution sum, a unique probability argmax matching `choice`, confidence, and nonnegative usage. The v1 selection policy accepts that unique validated argmax and records the full probability distribution, confidence, and token usage as evidence. It does not apply a separate confidence threshold.

The Jev key uses the dedicated `JevRouterAPIKey` secure-storage account. It is included in the complete repair inventory but excluded from provider/CLI, Claude-compatible, and frozen identity-migration inventories. The app-global credential service is shared across windows; each Settings window owns only its view model and observes live `APISettingsViewModel.agentAvailability`.

Startup readiness observation is noninteractive and network-free. The runtime bootstraps stored credentials only for an explicitly selected, enabled backend; inactive and disabled backends are not contacted. Selecting a backend while routing remains disabled also does not validate it—validation is an explicit Settings action.

## Adding a bundled backend

1. Implement `AgentTaskRouterBackend` with a stable lowercase ID.
2. Keep transport, credentials, response validation, and acceptance policy in the backend directory.
3. Register the adapter once in `AgentTaskRouterRuntime`; duplicate IDs are programmer errors.
4. Attach its redacted Settings presentation/actions controller to the registration without putting secrets or backend switches into generic state.
5. Test unknown selection, cancellation, readiness-generation changes, privacy, and normalized outcomes using the generic coordinator.
6. Return `selected` only after validating the response against the submitted opaque candidate set and the backend's versioned policy.

Adding a backend must not require changes to candidate construction, the semantic privacy contract, or provider runtimes.

## Generic host integration

For a new user-created Agent Mode session, the host reads the persistent policy after the final destination and execution location are ready, but immediately before `submitUserTurn`. It rechecks fresh-session eligibility, builds a router-owned frontier of up to twelve distinct executable targets from the live Claude Code and Codex catalogs, applies the optional primary-session provider requirement, and awaits the selected registration through exact coordinator ownership. The maintained frontier currently contributes economy, balanced, strong, and frontier model/effort points for each connected provider when those exact targets are available. One remaining target is applied locally without a Jev request. Selected targets are committed with provider, model, reasoning effort, and normalized ACP parameters. Any submission rejection rolls that complete target back without writing manual defaults. Abstention, failure, cancellation, and staleness block the send and retain the draft and explicit selection. Failed newly-created destinations are discarded and the exact source tab is reactivated.

RepoPrompt-managed `agent_run` and `agent_explore` starts use the same policy with subagent scope and its provider limit. Routing occurs before the provider session starts. An explicit compound `model_id` or explicit `model_parameters` request remains authoritative and bypasses global routing. Role-based and default child starts may be routed. A settings revision/backend fence rejects a result when the global policy changes while Jev is deciding.

An in-flight route is one ownership record indexed by both its source and final destination tabs. The visible destination exposes the exact cancel action, and either related tab rejects a second submit until that ownership settles. Cancellation removes both indexes before late backend completion can reach submission.

Jev's five-second deadline uses a first-result ownership bridge rather than structured task-group teardown: timeout or cancellation settles the caller immediately, cancels the transport task for cleanup, and filters any late result even if a transport ignores cancellation. Credential validation uses the same boundary, so generation cancellation cannot wait on or publish a late validation response.

When Router is disabled, top-level submission and MCP child-start selection follow their previous paths without creating a routing request. Continuations, steering, Chat/Oracle, Context Builder, and provider-owned nested behavior remain unchanged in both states.

## Jev selection policy

The current policy version binds the pinned `jev-1.13.0` evaluator to the v4 automatic-frontier expected-utility policy over the v2 session-routing contract. Jev receives two to twelve opaque criteria with human-readable provider/model/effort descriptions, dated capability and API-list-price evidence, scope, optional custom guidance, and utility-tier rubrics. The policy infers the complete expected work rather than over-weighting the task's first verb, prioritizes reliable completion, then avoids unnecessary cost and latency among targets with a clear capability margin. It treats retries, avoidable clarification, missed requirements, and incomplete work as costs rather than equating low token price with value. High effort on a weaker base model is explicitly not treated as stronger base-model capability. User guidance is an explicit preference and hard per-scope provider requirements filter candidates before the request. RepoPrompt accepts only a structurally valid response whose declared choice is the unique probability argmax. Authentication failure invalidates readiness for the credential generation that made the request. Transport, rate-limit, overload, timeout, and response-validation failures block the affected start; top-level failures retain the user's draft and explicit selection.

The evidence snapshot is versioned as `rpce.model-routing-evidence.2026-09-19`. Prices are provider-published API list prices per one million tokens, used only as a common comparison proxy because Claude Code and Codex subscription or credit billing can differ. Published benchmark results are identified as provider-reported and are not treated as perfectly comparable across harnesses. Unknown model identities state that capability and cost are uncertain instead of inheriting a guess from a nearby family.

Snapshot sources:

- OpenAI model pages for [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna), [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), and [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), plus the [GPT-5.6 evaluation table](https://openai.com/index/gpt-5-6/).
- Anthropic model pages or announcements for [Haiku 4.5](https://www.anthropic.com/news/claude-haiku-4-5), [Sonnet 5](https://www.anthropic.com/news/claude-sonnet-5), [Opus 5](https://www.anthropic.com/claude/opus), and [Fable 5.1](https://www.anthropic.com/claude/fable).

Refresh this evidence and advance its version when current aliases, frontier targets, prices, or material published evaluations change. Quality evaluation can refine the instructions, rubrics, pinned evaluator, evidence, or acceptance rule in a later version. Such a change must advance the policy version and keep deterministic wire and response-validation fixtures.

## Validation scope

Repository tests cover schema-v9 compatibility and schema-v10 scoped policy preservation, router-owned frontier construction independent of manual role settings, hard provider filtering, one-target local application, registration-owned Settings, readiness generation streams, transport cancellation, exact official Jev shapes, scope/guidance encoding, unique argmax/evaluator checks, authenticated backend routing, reservation-before-await coordinator ownership, prompt cancellation against non-cooperative backends, normalized optional evidence, and primary/subagent transaction placement. Live Jev quality and service availability require separate authorized-key validation; credentials and response bodies must never be committed or logged.
