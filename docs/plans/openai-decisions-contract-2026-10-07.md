# OpenAI Decisions wire contract record

**Checked:** 2026-10-11

**Access context:** Public first-party OpenAI developer documentation, unauthenticated; no account/API request was made.

**Purpose:** Phase 1 source record for the backend-private DTOs, interpreter, transport, and error classification. No credentials, account identifiers, or response bodies are recorded here.

## Sources

1. [Decisions guide](https://developers.openai.com/api/docs/guides/decisions) — public beta, model pin, request shape, choice/refusal semantics, illustrative response.
2. [Create a decision reference](https://developers.openai.com/api/reference/resources/decisions/methods/create) — HTTP method/path, body fields, question/choice schema, response/usage schema.
3. [API authentication overview](https://developers.openai.com/api/reference/overview) — Bearer authentication.
4. [API error codes](https://developers.openai.com/api/docs/guides/error-codes) — documented shared status/code categories.

## Request mapping

| Wire field | First-party evidence | Exact RPCE mapping | Status |
|---|---|---|---|
| `POST https://api.openai.com/v1/decisions` | Create reference, operation heading and endpoint; guide says dedicated `POST /v1/decisions` | Fixed HTTPS origin and exact path; no alternate endpoint | verified |
| `Authorization: Bearer …` | API authentication overview, “HTTP Bearer authentication”; Decisions guide request example | Caller-provided API key only; no key fallback or logging | verified |
| `model` | Decisions guide, “How decisions work”; currently `gpt-6-luna` only | Exact pin `gpt-6-luna` | verified |
| `input` | Create reference, Body Parameters: string or user-message array; Decisions guide request example uses text string | A single text string from the caller; no image, messages, files, or other context in Phase 1 | verified |
| `questions` | Create reference, Body Parameters: ordered question array; answers returned in question order | Exactly one question per request, preserving host model-then-effort sequencing | verified |
| question `type` | Create reference, Choice object: type is `choice` | Fixed string `choice` | verified |
| question `name` | Create reference, Choice object: optional string; answer carries corresponding name | RPCE supplies one nonempty expected name and requires the exact echo | verified |
| question `instructions` | Create reference, Choice object requires instructions string | Fixed backend instructions selected by a later adapter; wire layer sends supplied string as-is | verified |
| question `choices[].value` | Create reference, Choice object: string or boolean, typed values distinguish string and boolean | RPCE submits distinct opaque candidate keys as strings only | verified |
| question `choices[].description` | Create reference, description is optional string | Candidate explanation may be included when later adapter maps host candidates | verified |
| Other request properties | Create reference defines the relevant request fields; guide shows separate dependent requests | No `requestID`, safety identifier, images, streaming/storage/temperature flags, or other fields | verified (omitted) |

## Response mapping and acceptance

| Wire field / rule | First-party evidence | Exact RPCE mapping | Status |
|---|---|---|---|
| response `model` | Guide and reference examples use `gpt-6-luna`; guide says only that model currently available | Require exact pinned model | verified |
| `answers` | Create reference: answers returned in question order; guide example includes named answer | Require exactly one answer for the one submitted question | verified |
| choice answer `type`, `name`, `choice` | Create reference Choice answer schema and guide response example | Accept only `type=choice`, exact expected question name, and exact one of submitted opaque string keys | verified |
| `probabilities[]` (`value`, `probability`) | Guide choice response example and reference Choice answer schema | Keep array until validation; require one unique entry per submitted key and no extras | verified |
| `confidence` | Guide choice response example and reference Choice answer schema | Require finite `[0,1]`; project as optional host evidence; no calibration threshold | verified (range is RPCE validation policy) |
| typed `refusal` | Create reference: question can return refusal; named question refusal returns corresponding question name | A refusal with exact expected name is abstention; missing/wrong name is invalid | verified |
| `usage.input_tokens` | Create reference response schema/example | Required, integer, nonnegative; project input count | verified |
| `usage.input_tokens_details.cached_tokens` | Create reference response schema/example | Required, integer, nonnegative | verified |
| `usage.input_tokens_details.cache_write_tokens` | Create reference response schema/example | Required, integer, nonnegative | verified |
| `usage.output_tokens` | Create reference response schema/example | Required, integer, nonnegative; project output count | verified |
| `usage.output_tokens_details.reasoning_tokens` | Create reference response schema/example | Required, integer, nonnegative | verified |
| `usage.total_tokens` | Create reference response schema/example | Required, integer, nonnegative | verified |
| Unknown additive JSON members | API docs are descriptive; forward compatibility details not specified | DTOs ignore unknown additive keys, but reject missing/mistyped required keys and unknown answer discriminator | not specified (RPCE accepts additive fields) |
| Probability calibration/sum | The guide describes choice answers as a probability distribution; the reference does not specify a numeric sum tolerance or calibration guarantee | Require complete unique finite bounded values and `abs(sum - 1) <= 0.0001`; reject rather than renormalize invalid evidence | distribution semantics verified; tolerance is RPCE acceptance policy, not a provider guarantee |

## Error classification

The shared error guide is not Decisions-specific. This layer never exposes raw messages, never retries, and returns only redacted categories. Only verified structured code/type pairs receive specialized mapping; other bodies/statuses are conservative transport/policy failures.

| Status and structured error | First-party evidence | Exact RPCE mapping | Status |
|---|---|---|---|
| `400` | Error guide, API errors: malformed request / invalid request categories | `.invalidRequest`, no retry | verified |
| `401` invalid credential vs organization membership/IP authorization | Error guide lists invalid authentication and also organization-membership and IP-authorization 401 cases; no reliable wire discriminator was found in the cited source | `.policyUnavailable` until an authoritative discriminator is documented; must not invalidate a stored key based on status alone | blocked for credential invalidation policy |
| `403` unsupported region/access denial | Error guide lists unsupported region; permission-denied category | `.policyUnavailable`; do not invalidate key | verified |
| `429` `slow_down` with `rate_limit_error` | Error guide documents exact type/code pair | `.rateLimited` (retryable evidence only; no retry here) | verified |
| `429` `credit_balance_exhausted` | Error guide documents code | `.policyUnavailable` | verified |
| `429` `organization_spend_limit_exceeded` | Error guide documents code | `.policyUnavailable` | verified |
| `429` `project_spend_limit_exceeded` | Error guide documents code | `.policyUnavailable` | verified |
| `429` `organization_usage_limit_exceeded` | Error guide documents code | `.policyUnavailable` | verified |
| `429` other or absent code | No exact documented subtype in the cited guide (ordinary rate-limit entry does not name a code) | `.transport` conservative redacted failure, no credential invalidation/retry | not specified |
| `500` | Error guide: server-side error | `.overloaded` (retryable classification only; no client retry) | verified |
| `503` `service_unavailable_error` / `server_is_overloaded` | Error guide documents exact type/code pair | `.overloaded` | verified |
| Other status/code/type | No supported mapping established | `.transport` conservative failure | not specified |
| Invalid success JSON, oversized body, wrong shape | RPCE acceptance/transport policy, not provider error claims | `.invalidResponse`, nonretryable | verified (RPCE policy) |
| Cancellation / deadline / TLS or networking failure | RPCE transport policy | `.cancelled` / `.timeout` / `.transport` respectively; no retry | verified (RPCE policy) |

## RPCE-only limits and policy

These are product constraints, not claims about OpenAI service limits: the `0.0001` absolute probability-sum tolerance matches the existing Jev acceptance policy and is not an OpenAI-promised rounding bound; one non-streaming HTTP operation per invocation; no automatic retries or hedging; a five-second deadline through full response-body receipt; a decoded response-body cap of 64 KiB; reject redirects; fixed origin/path; request response parsed only after size-bounded receipt. Two sequential judgments therefore have at most ten seconds of remote deadline in the future staged adapter. A timeout does not establish whether the remote server processed or billed a request.

No endpoint-specific response-size, latency, question-count, idempotency, or capacity guarantee was found in the cited public documentation. Those remain provider unknowns and do not authorize widening RPCE limits.

## Contract uncertainty carried forward

The public shared error guide does not provide a reliable structured wire discriminator for distinguishing invalid/revoked credentials from other documented `401` causes. Phase 1 therefore refuses to classify every `401` as credential authentication. **Phase 2 must not invalidate credentials on a status-only `401`;** resolve this through authoritative provider evidence or retain conservative non-invalidating behavior and amend the planned readiness semantics before credential-layer integration.
