# Deferred Work

**Policy:** append-only after Phase 0 close. These items are intentionally outside
Phases 0–8 and must not be used to expand an earlier phase.

## Phase 9+ compatibility cleanup

1. Remove the legacy backend and construction-time selector after Core authority
   stabilizes.
2. Remove temporary app typealiases, forwarding adapters, and obsolete concrete
   implementations.
3. Convert transitional ownership/import guards into permanent source-layout and
   package guards.
4. Remove dead bridging-header declarations only after every caller imports its
   owning module.
5. Revisit access levels raised solely for extraction and lower them where
   external module use no longer requires exposure.

## Headless/Core convergence

Headless v1 intentionally duplicates mutable runtime components:

| Headless v1 component | Phase 9+ intended replacement |
| --- | --- |
| headless root registry | shared Core session/root authority |
| headless workspace/state store | `WorkspaceSessionController` persistence transactions |
| headless selection store | Core selection/revision controller |
| headless tool registry/dispatch | shared factual tool services plus product policy profile |
| headless file catalog/search path | `WorkspaceFileContextStore` and Core search |
| headless lifecycle/request registry | shared Core session handle/runtime admission |
| headless prompt state/renderer | Core factual prompt projection/accounting |

Convergence requires a separate characterized migration. Headless v1 must not
wrap or instantiate the app's current mutable engine as a shortcut.

## Separately planned work

- Additional MCP provider/catalog/DTO/formatter/dispatch extraction.
- Cross-platform/Linux/Windows support.
- Persisted schema redesign or migration.
- Moving app path, UserDefaults, approval, Git authorization, visible lifecycle,
  or diagnostics-presentation policy into Core.
- Broader performance optimization unrelated to preserving the frozen Phase 0
  baselines.
