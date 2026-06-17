## Why

`MCPServerViewModel.dashboard` already has a shared subscription lifecycle used by the toolbar popover and status view. The Orchestrator Dashboard should consume the same MCP dashboard stream, but adding another consumer touches shared MCP infrastructure that existing surfaces rely on. This should land as a small prerequisite before the dashboard UI consumes it.

## What Changes

- Add an explicit Orchestrator Dashboard consumer identity to `MCPServerViewModel.DashboardConsumer`.
- Preserve the existing ref-counted dashboard update lifecycle across toolbar popover, status view, and the new dashboard consumer.
- Validate that one shared dashboard subscription remains active while any consumer is visible and stops only after the last consumer hides.
- Do not add Orchestrator Dashboard UI or dashboard snapshot logic in this change.

## Capabilities

### New Capabilities
- `mcp-dashboard-consumers`: Allows multiple named MCP dashboard consumers, including the future Orchestrator Dashboard, to share the existing dashboard update stream safely.

### Modified Capabilities

None.

## Impact

- MCP infrastructure: extends `MCPServerViewModel.DashboardConsumer` and validates shared subscription behavior.
- Existing MCP UI: toolbar popover and status view must continue to subscribe/unsubscribe without regression.
- Orchestrator Dashboard: can depend on this change for its compact MCP footer/popover.
- Tests: requires lifecycle coverage for third-consumer visibility and last-consumer cleanup.
