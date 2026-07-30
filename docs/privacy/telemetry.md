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
