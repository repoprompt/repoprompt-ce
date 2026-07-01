# Telemetry

RepoPrompt CE can report crashes, errors, app hangs, and diagnostic signals that do not include
user content to [Sentry](https://sentry.io) to help us find and fix problems that affect people
running the app.
This document describes when telemetry is active, what is and is not collected, and how it is
configured.

## When telemetry is active

Telemetry is active only in official, notarized Developer ID builds that are configured with the
RepoPrompt CE Sentry project.

Telemetry is **not active by default** for:

- DEBUG builds,
- self-compiled / locally built CE,
- locally self-signed production builds,
- release-candidate (ad-hoc) builds,
- UI-test and stress-test launches.

This is enforced at build time and runtime. Builds without the telemetry-enabled app binary and a
Sentry DSN do not initialize telemetry. If you build CE yourself, telemetry is off unless you
explicitly configure a local build for Sentry testing.

## What is collected

When active, telemetry can capture:

- crash reports and unhandled errors, with stack traces,
- app-hang reports,
- the app version/build and OS version,
- a bounded set of explicitly instrumented breadcrumbs leading up to an event,
- explicitly instrumented traces/spans for coarse app workflow timing, without user content,
- explicitly instrumented metrics for aggregate usage shape, without user content.

The configuration is deliberately conservative:

- no personally identifying information (`sendDefaultPii = false`),
- no session replay, MetricKit, structured logs, automatic network breadcrumbs, or automatic file I/O tracing,
- only explicitly instrumented breadcrumbs, spans, and metrics that do not include user content,
- breadcrumb and on-disk event caches are bounded.

## What is not sent

RepoPrompt CE's app-owned telemetry is data-minimized by construction: call sites emit typed
lifecycle events instead of raw app data. The telemetry model uses closed enums,
booleans, counts, and buckets; it does not accept arbitrary `String` values for event attributes.
The following are not collected by the manual telemetry instrumentation:

- prompts and conversation transcripts,
- selected file contents,
- absolute file system paths and workspace names,
- tool arguments and results, and MCP payloads,
- AI provider request/response bodies,
- command output,
- run IDs and tool invocation IDs,
- custom or free-form external tool names,
- raw model names,
- environment variables,
- API keys, tokens, bearer credentials, and passwords,
- screenshots, view hierarchy, and session replay.

Sentry native crash reports include SDK-provided crash context such as stack traces, exception
messages, app version/build, OS version/build, device model, locale, memory values, a generated user
identifier, and coarse geo country.

## Processor

Telemetry data is processed by Sentry (a third-party SaaS provider) acting as a data processor on
behalf of the RepoPrompt CE project.

Sentry project-side data scrubbing is also configured for the project as defense-in-depth.
It is not the primary privacy boundary: RepoPrompt CE avoids sending sensitive data from the
app in the first place.