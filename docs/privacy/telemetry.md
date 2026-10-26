# Telemetry

RepoPrompt CE can report privacy-respecting crash and diagnostic information to
[Sentry](https://sentry.io) to help maintainers fix problems that affect people running the app.
Telemetry is opt-out in official telemetry-capable builds and can be disabled at any time.

## How to turn telemetry off

Open **Settings → Telemetry** and turn off **Share crash reports and diagnostics**.

You can also disable telemetry for a process before launching the app:

```bash
REPOPROMPT_TELEMETRY_DISABLED=1 /Applications/RepoPrompt\ CE.app/Contents/MacOS/RepoPrompt
```

The environment variable wins over Settings for that launch. When telemetry is turned off in
Settings after the SDK has started, RepoPrompt closes the Sentry SDK so the app stops capturing new
events. Sentry Cocoa 9.17.1 does not expose a stable public API for selectively purging queued event
envelopes; RepoPrompt keeps the SDK cache small and closes the SDK as the safest available behavior.

## When telemetry is active

Telemetry can send data only when all of the following are true:

- the app was built with Sentry support,
- a Sentry DSN is present in the signed app bundle,
- **Share crash reports and diagnostics** is enabled in Settings,
- `REPOPROMPT_TELEMETRY_DISABLED` is not set to a truthy value.

Telemetry is normally inactive for DEBUG builds, self-compiled/local CE builds, locally self-signed
production builds, release-candidate ad-hoc builds, UI-test launches, and stress-test launches.
Local DEBUG builds may use `REPOPROMPT_SENTRY_DSN` only for integration testing; official release
telemetry uses the signed bundle's `RepoPromptSentryDSN` instead.

## Account usage limits (separate from diagnostic telemetry)

The optional usage-limit display is controlled by **Settings → Agent Mode → Overview →
Show usage limits when available**. This presentation preference does not authorize credential
access or change model selection. Codex usage must be enabled separately; it uses a dedicated
Codex app-server account read and account notifications without creating a conversation.

Claude usage requires explicit **Connect Claude usage** consent in CLI Providers for one Claude
Code config-folder profile. Prior OAuth consent does not authorize this changed method. A short-lived,
hidden terminal process runs the user's unmodified Claude Code, opens its built-in `/usage`, and
consumes its documented status-line JSON. RepoPrompt does not read Claude login tokens or call
account endpoints itself. Claude Code owns authentication, including any refresh it performs, and
may update its own ordinary session bookkeeping. RepoPrompt writes only per-run settings in a
private app-owned directory, never user/project Claude settings. User/project setting sources are
excluded, explicit hooks are empty, and tools/MCP servers are disabled; managed policy is not
bypassed. `disableAllHooks` is deliberately omitted because Claude also uses it to suppress the
status-line collector. No model prompt is submitted and no trust or login prompt is approved
automatically. If CLI setup prevents startup, the read fails closed.
The first **Connect and open setup** confirmation opens Terminal for the user to approve the
helper folder or sign in themselves. A clearly styled **Finish Claude setup…** action is also
available beside unavailable readings, with another setup action under Details. Each uses that
same isolated folder/configuration, sends no model message, and opens Terminal only after an
explicit user confirmation. The first Connect defers collection until the user chooses
**Check usage after setup**. Pending setup remains visible after a restart and is not reported as
completed collection. Preparing setup requires profile-scoped consent, not completed setup;
background collection still requires both. If Terminal cannot open the prepared helper, the
setup sheet shows the concrete error and a selectable, copyable manual command with trust/sign-in
and completion instructions. Setup completion starts a new generation so a pre-setup failure
cannot consume the ordinary Refresh cooldown. Normal refreshes remain hidden.

Claude checks once when usage is first demanded after launch/enable, plus manual Refresh with a
60-second minimum gap. There is no periodic Claude polling or permanent helper. Hidden surfaces or
the master preference being off cancel active collection. The local statistics cache is loaded before
the startup refresh and retains the original observation date; expired/aged values remain stale.
Only percentages, reset times and non-secret cache/profile metadata are persisted in private files.
Account identity is unknown, so these readings cannot supply routing eligibility or account-balancing
signals. Disconnect removes the statistics cache. Codex snapshots remain in memory in this change.

The Claude-only opt-in disclosure explains this method and that Anthropic has not explicitly approved
automated usage monitoring; using documented CLI features is not a compliance guarantee. Account
identities, credentials and raw terminal output are not logged or sent to diagnostic telemetry. Legacy
Claude run-event telemetry remains separate and cannot authorize usage collection.

## Agent Mode Re-prompt (model requests, not telemetry)

Re-prompt v2 is off by default and enabled separately in each window. With consent, the first Send
sends eligible local composer text, rewrite guidance and a bounded manifest (root names and selected
relative paths) to the resolved **Re-prompt model**, independently of the primary Oracle. Default resolution
prefers connected native Claude Code / Codex subscriptions, matching the current agent's provider
when possible, then the other subscription, then configured fast API tiers (Sonnet 5.5,
GPT-6.1 Sol Low, Gemini 3 Flash), then none. No arbitrary catalog-first or primary Oracle fallback
is used. Other configured models require an explicit choice. The UI names the concrete model or
shows a chooser with an actionable unavailable reason when no supported model is connected. The pill refreshes
when connected models load; a first-use default does not require manual selection. Losing a default after use does not silently switch
billing routes. Explicit models never fall back. A call freezes its billing route; failure/retry cannot switch it. The provider's retention
and billing terms apply; do not send secrets you do not want that recipient to receive.

**Include recent chat context** is on by default and persisted in the selected Agent Models
profile (available in Settings and the pill's right-click menu). Only sessions with at least two prior completed user turns may send excerpts:
the last up to three prior user bubble texts (the rewritten text when applicable) and each turn's
final assistant reply, trimmed to approximately 1.5 KiB retaining start and end. The serialized
excerpt budget is 8 KiB; oldest turns are dropped first. Only post-compaction turns qualify.
Tool calls/results, thinking, diffs, attachment payloads and system/workflow envelopes are excluded.
The strip says **with chat context** when excerpts are actually used. Fixed, non-editable framing
makes history background for vocabulary/intent only: the current message always wins, assistant
claims are unverified, and corrections/redirections must abandon rather than perpetuate failed
approaches. Turn history never creates new requirements unless the current message restates them.

Calls are stateless and tool-less: **no Oracle consults, Context Builder, repository file contents,
git review packaging or selection mutations**. Composer attachments/tagged files are preserved
locally but their payloads are not sent to the rewriter. Transient Before sending questions are not
provider-history rows. Substantive answers may cause one refinement from original text plus answers;
skipping questions does not refine. Versioned disclosure receipts cover the recipient and recent-
chat exposure. First enable shows a concise recipient, payload, retention/billing and automation summary;
operating instructions are expandable rather than a blocking wall of text.

The brief streams into the existing composer, read-only during preparation. **Review before
sending** is the default: successful preparation unlocks editing and Return dispatches the current
draft without rewriting it again. The opt-in, profile-scoped **Send automatically** mode dispatches
a successful rewrite through ordinary fresh-claim admission on completion; any clarification questions
force Review for that turn, even if skipped. Slash-leading generated or edited text also forces
Review, with a warning that the provider may interpret it as a command; only a deliberate subsequent
Send can dispatch it. Cmd+Return always prepares for Review (including a
one-shot when the pill is off), using current edited text or the first original when unchanged.
The header retains that first original inline. Esc cancels streaming or reverts a completed draft;
the edited rewrite stays available through undo/recovery. Send original is available immediately as an explicit second Send action through
fresh-claim admission. Cancel/Esc restores the original; Undo preserves the edited brief in the local
recovery banner. Invalidation (tab/target/settings changes or Stop) also restores the original when
the composer is still operation-owned. New edits stay intact with explicit Restore original / Keep
rewrite choices, rather than silently starting another rewrite from generated output. Truncated output
is recoverable but cannot be sent as a successful preparation.
Draft text follows ordinary composer draft persistence; clarification/recovery state stays in memory.

Re-prompt uses the selected model's low-effort variant when available, without a separate Auto Effort
judgment call. The first Return prepares a rewrite; the next Return in that composer explicitly
sends the current text, including during preparation, with no timing deadline. Late rewrite output
is cancelled and fenced. Clarifications appear once in a compact, height-bounded scrollable panel
above the composer (at most one question and three options). Finishing or dismissing clarification
requests native composer focus restoration only in the key window and only when focus has fallen
back to a container or a removed control; a live unrelated text field keeps focus. Cmd+Shift+O sends
the original during preparation. Optional clarification can be skipped with Cmd+Shift+K; Cmd+Option+1–3
chooses an offered answer. At local send admission, the editor clears immediately and a transient **Sending**
preview shows the message while routing/session preparation finishes; it is not persisted as a sent transcript turn.
A blocked or cancelled preparation restores the captured draft above newer typing, retaining its original/rewrite
recovery. Pending sends lock attachment/workflow controls and offer Cancel/Esc. Successful submission replaces
the pending preview with the ordinary transcript turn and retires only its captured recovery state.
Router/implementing-turn Auto Effort speculation starts only after a complete brief, never partial
tokens, and is discarded on edits or stale policy. These opted-in services may have received the
complete draft even if it is later undone. Composer edits are never sent back to the rewrite model.
No implementing turn is sent speculatively. Minimal local automation audits store outcomes and
reuse/fallback flags, not message text, guidance, excerpts, answers, paths or generated briefs.
These model calls are independent of **Share crash reports and diagnostics**.

## What is collected

When active, RepoPrompt can send:

- crash reports and unhandled exception diagnostics with stack traces,
- app-hang reports when **App hang reports** is enabled; this sub-option defaults off for release safety,
- app version/build, OS version, environment, and SDK metadata,
- a conservative sample of app startup performance traces when **Performance timing and tracing** is enabled.

Production performance tracing defaults to off. Sentry Cocoa automatic release-health session tracking
is explicitly disabled because the pinned SDK stores and sends a persistent installation identifier as
the session `did`; RepoPrompt prefers not to collect that stable identifier. Manual tool-stack
breadcrumbs, metrics, per-message transcript hooks, MCP tool execution spans, and agent-run state
metrics are disabled/deferred in this telemetry pass.

The runtime configuration is deliberately conservative:

- `sendDefaultPii` is false,
- no session replay, release-health auto sessions, MetricKit, structured logs, automatic failed-request
  capture, automatic network breadcrumbs, automatic network tracking, automatic file I/O tracing, or
  Core Data tracing,
- a small bounded Sentry cache and breadcrumb limit,
- a `beforeSend` scrubber that removes the Sentry request object, request payload fields, user and
  geo fields, server names, stable device identifiers, installation/vendor/advertising identifiers,
  and redacts obvious secrets, arbitrary macOS user-home paths, and IP-like values from event fields
  exposed by Sentry Cocoa,
- typed traversal of event, thread, and exception stack traces, exception mechanisms, frame
  registers/variables/context, and debug images; user-local values in path-bearing frame and debug
  image fields are removed while symbolication identifiers and addresses are preserved,
- removal of Sentry `dist` in `beforeSend`, after the pinned SDK has restored the bundle build number
  during event preparation.

## What is not sent

RepoPrompt CE does not intentionally send:

- prompts or conversation transcripts,
- selected file contents,
- tool arguments, tool results, MCP payloads, or command output,
- AI provider request/response bodies,
- API keys, tokens, bearer credentials, passwords, or environment variables,
- workspace names, run IDs, tool invocation IDs, or raw model names,
- screenshots, view hierarchy, session replay, or automatic release-health session identifiers.

Native crash reports may include SDK-provided crash context such as stack traces, exception messages,
app/OS versions, device model, locale, and memory values. RepoPrompt disables default PII, disables
Sentry's automatic failed-request and release-health session capture, and applies its own scrubber
before events are sent.

For pinned Sentry Cocoa 9.17.1, crash and app-hang conversion populates typed frames, exceptions, and
debug images before `beforeSend`; RepoPrompt clears the SDK-restored `dist` and scrubs those fields
before event serialization. Already-serialized envelopes cached by an older build are not rewritten.
Sentry's user-feedback event type bypasses `beforeSend`, but RepoPrompt does not expose or capture that
event type. The envelope header can carry SDK-generated trace-routing metadata outside the serialized
event item; RepoPrompt does not put prompts, file contents, workspace names, or user identifiers there.
Sentry also runs global event processors after `beforeSend`; RepoPrompt registers none, and adding one
that restores unsanitized data would violate this boundary. SDK upgrades must revalidate crash/hang
conversion, callback order, processor order, and envelope serialization before this promise is carried
forward.

## Processor

Telemetry data is processed by Sentry (a third-party SaaS provider) acting as a data processor on
behalf of the RepoPrompt CE project. Sentry project-side data scrubbing is maintained as additional
defense-in-depth where available; RepoPrompt's primary privacy boundary is avoiding sensitive data
collection in the app before upload.
