## ADDED Requirements

### Requirement: Named MCP dashboard consumers
The system SHALL support a named MCP dashboard consumer for the Orchestrator Dashboard without changing existing dashboard consumers.

#### Scenario: Orchestrator Dashboard consumer is available
- **WHEN** MCP dashboard consumers are referenced
- **THEN** the system SHALL provide a named Orchestrator Dashboard consumer identity alongside existing toolbar popover and status view consumers.

#### Scenario: Existing consumers remain available
- **WHEN** existing MCP UI surfaces subscribe to dashboard updates
- **THEN** toolbar popover and status view consumers SHALL continue to use their existing consumer identities and behavior.

### Requirement: Shared dashboard subscription lifecycle
The system SHALL keep one shared MCP dashboard update subscription active while any dashboard consumer requires it.

#### Scenario: First consumer appears
- **WHEN** no dashboard consumer is visible and one dashboard consumer becomes visible
- **THEN** the system SHALL start MCP dashboard update observation.

#### Scenario: Additional consumer appears
- **WHEN** dashboard update observation is already active for one visible consumer and another consumer becomes visible
- **THEN** the system SHALL keep using the shared dashboard update observation path
- **AND** it SHALL NOT start a duplicate dashboard update task solely because another consumer appeared.

#### Scenario: One of multiple consumers disappears
- **WHEN** multiple dashboard consumers are visible and one consumer becomes hidden
- **THEN** the system SHALL keep MCP dashboard update observation active for the remaining visible consumer or consumers.

#### Scenario: Last consumer disappears
- **WHEN** the final visible dashboard consumer becomes hidden and window tools do not otherwise require dashboard observation
- **THEN** the system SHALL stop MCP dashboard update observation
- **AND** it SHALL clear dashboard snapshot state according to the existing lifecycle.

#### Scenario: Window tools force observation
- **WHEN** window tools require dashboard observation independent of visible dashboard consumers
- **THEN** the system SHALL keep MCP dashboard update observation active even if the dashboard consumer set is empty.
