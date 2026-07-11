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
