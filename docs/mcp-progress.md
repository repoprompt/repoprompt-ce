# MCP progress for long-running tools

RepoPrompt CE reports observable progress for long-running Context Builder and
Oracle work without changing the final tool result or cancellation contract.

## Standard MCP clients

A client requests progress by including a unique `progressToken` in the
`_meta` object of its `tools/call` request:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "context_builder",
    "arguments": {
      "instructions": "Trace the authentication path"
    },
    "_meta": {
      "progressToken": "context-builder-42"
    }
  }
}
```

While the request is running, RepoPrompt CE sends standard
`notifications/progress` notifications with the same token. The `progress`
field is a monotonically increasing event sequence, not a percentage. The
`total` field is omitted because discovery and model generation do not have a
reliable fixed work total.

This follows the MCP
[progress utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress):
the receiver echoes the caller's token and keeps progress values increasing for
that request.

Context Builder messages include the active stage and detailed phase, such as
model resolution, payload packaging, response streaming, tab-context commit,
or workspace persistence. Long phases also emit heartbeats.

Nested provider startup and routing use these ordered `discovering` phases:

- `provider_process_starting`
- `waiting_for_child_connection`
- `child_connection_observed`
- `waiting_for_routing`
- `routing_confirmed`
- `routing_timeout_before_connection`
- `routing_timeout_after_connection`

The top-level `starting` stage is reserved for setting up the Context Builder
tool call itself. `provider_process_starting` remains under `discovering`
because it starts the nested discovery provider after tool setup is complete;
the word “starting” in the phase name does not move it back into the tool's
top-level setup stage.

`child_connection_observed` means the connection matched the exact run-owned
client-name/PID policy. It is intentionally sticky: if route installation later
rolls back, the connection was still observed, so an unchanged routing deadline
that subsequently expires is reported as `routing_timeout_after_connection`.
Explicit routing failure or cancellation is not mislabeled as a timeout.
These phases are observations only and do not change provider launch, routing,
timeout, cleanup, cancellation, or final-result behavior.

Clients that omit `_meta.progressToken` receive the same final result but do not
receive standard progress notifications. A host may also choose not to render
notifications it receives.

## `rpce-cli` behavior

Non-interactive `rpce-cli -e` calls request a unique standard progress token and
print progress messages to stderr:

```text
[progress] context_builder [discovering]: Running Context Builder agent...
[progress] context_builder [discovering]: Still in tab-context commit ...
[progress] context_builder [generating]: Oracle response streaming started ...
```

Stdout remains valid MCP or command output. RepoPrompt's older
`repoprompt/control/progress` notification remains available as a compatibility
fallback when a bundled CLI talks to an older app build.

Progress is advisory. A dropped notification does not fail the tool call.
Cancelling the request still uses MCP request cancellation and stops the
underlying Context Builder work through the existing lifecycle path.
The server invalidates request progress before returning the final result and
drains notifications already accepted for delivery, so heartbeat, soft-bound,
and timeline delivery tasks cannot emit against a completed request.
