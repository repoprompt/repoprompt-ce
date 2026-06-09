# Agent Provider Plugin Seam

Current as of 2026-05-13. This document is contributor-facing: use it when you are wiring a new autonomous-agent provider, editing the Claude-compatible runtime, or moving code across the core ↔ plugin boundary.

## Scope and goals

RepoPrompt CE keeps a small, provider-neutral runtime contract in the app and pushes provider-specific protocol/codec/runtime logic into a Swift package product. The first plugin product is `RepoPromptClaudeCompatibleProvider`, which owns the Claude-compatible family (Claude Code, GLM/Zai, Kimi, custom Claude-compatible). The seam preserves:

- public `AgentProviderKind` raw values;
- `AgentProviderBindingID.claude` settings/permission grouping;
- persisted `AgentModel` raw values, option ordering, and provider defaults;
- secure permission documents in `AgentPermissionSecureStore`;
- `.claude` legacy/mirror keys for tool/permission settings.

The seam intentionally stops short of dynamic plugin loading. It is static SwiftPM composition and an internal DTO-based plugin API.

## High-level layering

```
+--------------------------- core (RepoPrompt target) ---------------------------+
|                                                                                |
| AgentMode/UI · transcript · tool tracking · MCP permission · run state         |
|     │                                                                          |
|     │  NativeAgentRuntimeControlling (provider-neutral core contract)          |
|     ▼                                                                          |
| ClaudeCompatibleNativeSessionAdapter ─┐                                        |
| ClaudeCompatibleHeadlessProviderAdapter ├─ Agent Mode adapter trio             |
| ClaudeCompatibleModelCatalogAdapter ──┘                                        |
|     │                                                                          |
|     │  ClaudeCompatiblePluginBridge (feature bridge / Agent-Mode mappings)     |
|     │                                                                          |
|     │  ClaudeCompatibleProviderRuntimeBridge (infrastructure / package import) |
|     ▼                                                                          |
+--------------------- package (RepoPromptClaudeCompatibleProvider) -------------+
|                                                                                |
| Plugin DTOs · prompt delivery · environment builder · catalog · headless args ·|
| launch env resolver · Claude SDK codec/translator (pure logic)                 |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Two thin facades sit between core and the package so lower-level infrastructure files (for example `ClaudeCodeLaunchEnvironmentResolver`) do not depend upward on Agent Mode:

- **`ClaudeCompatibleProviderRuntimeBridge`** (`Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`) is the single core import point for `RepoPromptClaudeCompatibleProvider`. It owns the package's type aliases, DTO conversions, and pure runtime helpers (prompt delivery, environment building, model normalization, headless argument construction, launch-environment resolution, catalog snapshots, stream-result mapping).
- **`ClaudeCompatiblePluginBridge`** (`Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`) is the Agent-Mode-facing facade. It maps `AgentProviderKind` to the package's `ClaudeCompatibleProviderPluginID`, derives availability, builds runtime configs from Agent Mode / discovery contexts, and forwards every other helper to the infrastructure bridge.

Anywhere outside these two files, core code interacts with Claude-compatible plugin DTOs through one of the bridges, not through a raw package import.

## Static dependency setup

The provider package lives in-repo at `Packages/RepoPromptAgentProviders/` and is composed into the root manifest with SwiftPM's path-dependency form:

```swift
// Package.swift (root)
.package(path: "Packages/RepoPromptAgentProviders"),

// RepoPrompt executable target dependencies
.product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders"),
```

The package itself exposes a single library product today:

```swift
// Packages/RepoPromptAgentProviders/Package.swift
products: [
    .library(
        name: "RepoPromptClaudeCompatibleProvider",
        targets: ["RepoPromptClaudeCompatibleProvider"]
    ),
],
```

The package target is Foundation-only and intentionally does **not** import any RepoPrompt app code, persistence layer, or secure storage.

### Test commands

```bash
# Root app builds and tests (includes the package transitively):
swift build --product RepoPrompt
swift test

# Package-only tests (faster iteration on codec / translator / catalog DTOs):
cd Packages/RepoPromptAgentProviders
swift test
```

### Future external repository

When the provider package is later moved to its own repository, the plan is:

1. Replace the path dependency in the root `Package.swift` with a versioned remote dependency:
   ```swift
   .package(url: "https://github.com/.../RepoPromptAgentProviders.git", from: "x.y.z"),
   ```
2. Document a SwiftPM/Xcode local override for sibling-checkout development rather than re-introducing a required `.package(path:)` in the shared manifest. Two equivalent override options:
   - Xcode → File → Add Package Dependencies → Add Local… pointing at the sibling checkout (Xcode-only override).
   - `swift package edit RepoPromptAgentProviders --path ../RepoPromptAgentProviders` (writes the override into `.swiftpm/`).
3. Keep `Packages/RepoPromptAgentProviders/` in the open-source repo as long as it is the canonical staging location; once split out, mirror updates with versioned releases instead of in-tree edits.

The remote-by-default policy avoids breaking checkouts that do not have a sibling clone, while still giving contributors a low-friction local edit workflow.

## Core vs plugin ownership

| Concern | Owner |
| --- | --- |
| `AgentProviderKind`, `AgentProviderBindingID`, runtime kind strings | core |
| Persisted settings (`UserDefaults`, secure store, `.claude` documents) | core |
| `ClaudeAgentToolPreferences`, `ClaudeCodeCompatibleBackendConfig`, `ClaudeCodeCompatibleBackendStore` | core |
| MCP permission policies, RepoPrompt MCP auto-approval, tool tracking | core |
| Agent Mode transcript mutation, tool-card UI, run-state ownership | core |
| Native process control (`ClaudeNativeProcessSessionController`) | core (this wave) |
| Provider-neutral runtime contract (`NativeAgentRuntimeControlling`) | core |
| Provider-neutral RepoPrompt workflow prompt catalog and renderers (`Infrastructure/AI/Prompts/Workflows`) | core |
| Headless wrapper (`ClaudeCodeAgentProvider`) | core (delegates pure rules to package) |
| `AgentModel` raw values, option DTOs, defaults | core (adapter forwards plugin DTOs back to these) |
| Plugin IDs (`ClaudeCompatibleProviderPluginID`), runtime variants, backend IDs | package DTOs |
| Claude SDK protocol codec and NDJSON translator | package |
| Prompt delivery rules (XML wrapping, system-prompt overrides) | package |
| Compatible-backend environment builder, removed env keys, no-model raw values | package |
| Launch-environment resolver (slot mapping, model normalization, GLM legacy aliases) | package |
| Headless CLI argument construction | package |
| Model catalog snapshot (string options, default raws, supported effort levels) | package |
| Stream-result DTO (`ClaudeProviderStreamResult`, `ClaudeProviderJSONValue`) | package |

The package never touches `UserDefaults`, `Keychain`, or `AgentPermissionSecureStore`. Secrets and persisted backend configs are read in core, sanitized into plugin DTOs (`ClaudeCompatibleBackendConfig`, `ClaudeCompatibleLaunchEnvironment`), and handed to the package at launch/catalog time through bridge functions and provider closures.

## Bridge responsibilities

### `ClaudeCompatibleProviderRuntimeBridge` (infrastructure)

Path: `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`.

This is the only file in core that `import RepoPromptClaudeCompatibleProvider`. It is responsible for:

- declaring `ClaudeCompatiblePlugin…` type aliases for every package DTO core code references, so other files can refer to plugin types without importing the package;
- converting core enums/structs to plugin DTOs and back (`pluginRuntimeVariant(for:)`, `pluginBackendID(for:)`, `pluginBackendConfig(from:)`, `runtimeConfig(from:)`, `launchEnvironment(from:)`, `coreLaunchEnvironment(from:)`, etc.);
- forwarding pure runtime helpers from the package: `ClaudeCompatiblePromptDelivery`, `ClaudeCompatibleBackendEnvironmentBuilder`, `ClaudeCompatibleHeadlessRuntime`, `ClaudeCompatibleLaunchEnvironmentResolver`, `ClaudeCompatibleModelCatalog`, `ClaudeCompatibleModelNormalizer`;
- translating package errors (`ClaudeCompatibleProviderError.invalidConfiguration`) into core errors (`AIProviderError.invalidConfiguration`);
- mapping `ClaudeProviderStreamResult` to `AIStreamResult` and back, so plugin DTOs never leak into Agent Mode and core stream results never leak into the package.

Files that depend on this bridge (illustrative):

- `Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift` (stream mapping)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeLaunchEnvironmentResolver.swift` (model normalization, slot mapping, launch resolution)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeCompatibleBackendStore.swift` (env builder)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodePromptDelivery.swift` (decorated user message)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeAgentToolPreferences.swift` (prompt delivery rules)
- `Infrastructure/AI/Providers/ClaudeCodeAgentProvider.swift` (headless arguments, user-message decoration)

### `ClaudeCompatiblePluginBridge` (Agent Mode feature facade)

Path: `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`.

Responsibilities the infrastructure bridge cannot cleanly own because they require Agent-Mode-only concepts:

- `pluginID(for: AgentProviderKind)` / `agentKind(for: ClaudeCompatiblePluginID)` – the only place Agent Mode's provider kind talks to package IDs.
- `agentModeRuntimeConfig(...)` and `discoveryRuntimeConfig(...)` – build a `ClaudeCompatibleRuntimeConfig` from `ClaudeCodeAgentConfig.agentMode(...)` / `.discovery(...)` while staying tied to `AgentProviderKind`.
- `availability(for:)` – combines `AgentModelCatalog.isAgentAvailable(...)` with package availability shapes.
- `streamResult(from:)` / `providerStreamResult(from:)` – Agent-Mode-facing wrappers re-exported for the adapter trio.

Everything else is a thin pass-through to `ClaudeCompatibleProviderRuntimeBridge`.

## Adapter trio

The Agent Mode side of the bridge ships three small adapters under `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/`.

### `ClaudeCompatibleNativeSessionAdapter`

- Carries a `ClaudeCompatiblePluginRuntimeConfig` and delegates `NativeAgentRuntimeControlling` to a controller factory closure.
- Today the factory returns a `ClaudeNativeProcessSessionController` (core-owned process control). A future slice can replace the factory body with a package-driven controller without changing the adapter's public shape.
- `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` is the single call site that constructs and hands the adapter to `ClaudeAgentModeCoordinator`.

### `ClaudeCompatibleHeadlessProviderAdapter`

- Wraps a concrete `HeadlessAgentProvider` (currently `ClaudeCodeAgentProvider`) and carries a `ClaudeCompatiblePluginRuntimeConfig` for parity with the interactive adapter.
- `AgentRuntimeProviderService.makeProvider(...)` branches for `.claudeCode | .claudeCodeGLM | .kimiCode | .customClaudeCompatible` build the underlying provider and wrap it in this adapter. Non-Claude providers (Codex, Gemini, OpenCode, Cursor) bypass the adapter.

### `ClaudeCompatibleModelCatalogAdapter`

- Asks the package for a `ClaudeCompatibleModelCatalogSnapshot`, then canonicalizes raw values back onto `AgentModel.resolvedModel(...)` and existing GLM legacy aliases.
- Owns the public Agent-Mode-facing helpers `AgentModelCatalog` forwards to for Claude-compatible branches: `defaultModelRaw(for:)`, `options(for:)`, `isValid(rawModel:for:availability:)`, `claudeEffort(...)`, plus compatible-backend display/description lookups.
- Keeps `AgentModel` raw values and validation semantics stable so persisted user selections survive the seam.

## Provider-neutral native runtime contract

Path: `Sources/RepoPrompt/Features/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift`.

This is an **app-internal** contract, not the external plugin API. It still uses core models (`AIStreamResult`, `AgentApprovalRequest`, `AgentApprovalDecision`) because adapters translate plugin DTOs first. The current shape:

```swift
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    func sendUserMessage(_ text: String) async throws -> UUID
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}
```

The associated event/session/turn types are currently `typealias`es over the Claude-native runtime DTOs (`NativeAgentRuntimeEvent = ClaudeNativeProcessSessionController.Event`, etc.). When a second native provider arrives, the aliases will become proper neutral DTOs and the Claude controller will conform via its own mapping. Until then the alias layer keeps the seam ergonomic without forcing churn on coordinators, runners, and tab-session storage.

`ClaudeSessionControlling` is retained as a backwards-compatible alias for existing Claude call sites.

## ACP provider MCP tool-call timeouts

RepoPrompt CE cannot impose one MCP tool-call timeout across external ACP providers; configure the provider where supported.

- **OpenCode:** Timeout values are milliseconds. For a 10,000-second call, set `"timeout": 10000000` on the existing RepoPrompt MCP server entry, preserving its `type`, `command`, and `environment` fields.
- **Cursor Agent:** Current builds expose no supported ACP, CLI, environment, or configuration override that RepoPrompt CE can set to 10,000 seconds. Do not add a speculative CE timeout control; add one only if Cursor documents a supported configuration surface.

## How a new provider plugs in

The recommended pattern when adding (for example) a hypothetical `acmeAgent` family:

1. **Decide the runtime shape.**
   - Interactive native CLI: implement `NativeAgentRuntimeControlling` for the new family, building an adapter analogous to `ClaudeCompatibleNativeSessionAdapter`.
   - Headless-only CLI: build a `HeadlessAgentProvider` and (optionally) wrap it in a per-family adapter for parity.
   - ACP-based: follow `Sources/RepoPrompt/Features/AgentMode/Providers/ACP/ACPAgentProvider.swift` instead — ACP runtimes do not yet flow through the Claude-compatible plugin seam.

2. **Add (or reuse) a provider package.**
   - For an external family with its own SDK/codec, add a new library product under `Packages/RepoPromptAgentProviders/Sources/RepoPromptAcmeProvider/` and register a Swift target in the package manifest.
   - Keep DTOs Foundation-only. Use a `Sendable` JSON value type rather than `[String: Any]`.
   - Add package-level tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptAcmeProviderTests/` covering codec, translator, prompt delivery, and catalog snapshots.

3. **Wire the package into core through a bridge.**
   - Add one infrastructure file that imports the new package and declares `Acme…` type aliases, DTO conversions, and pure-helper forwarders. Mirror `ClaudeCompatibleProviderRuntimeBridge`.
   - Add an Agent-Mode-facing facade if the new family needs `AgentProviderKind` mappings, availability rules, or runtime-config builders.

4. **Add the adapter trio.**
   - `AcmeNativeSessionAdapter` (if interactive), `AcmeHeadlessProviderAdapter`, `AcmeModelCatalogAdapter`.
   - The native adapter conforms to `NativeAgentRuntimeControlling` and delegates to a factory closure so the controller implementation can move between core and the package later.

5. **Extend the runtime/factory wiring.**
   - Add the new cases to `AgentProviderKind` and the supporting maps (`commandName`, `displayName`, `mcpClientNameHint`, `runtimeKind`, `usesClaudeNativeRuntime` / new flags, `claudeRuntimeVariant` if relevant, `agentDescription`).
   - Extend `AgentProviderBindingID` if the new family needs its own permission/settings grouping; otherwise reuse an existing binding ID and keep secure-store documents grouped accordingly.
   - Add a branch in `AgentRuntimeProviderService.makeProvider(...)` that builds the headless provider and wraps it in the new adapter.
   - For interactive runs, add a sibling of `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` that constructs the adapter; pass it through `ClaudeAgentModeCoordinator`'s factory or add a coordinator analogue if the new family needs distinct steering rules.

6. **Plug into the model catalog.**
   - Forward the new family's branches in `AgentModelCatalog` to `AcmeModelCatalogAdapter` so option ordering, defaults, validation, display names, and discovery payloads come from the package while preserving `AgentModel` raw values for persisted user selections.

7. **Keep persistence in core.**
   - Settings/backend stores live under `Infrastructure/AI/Providers/Acme/` and are sanitized into plugin DTOs at launch time.
   - Secrets pass through `@Sendable` provider closures (see `ClaudeCompatibleLaunchEnvironmentResolver`'s `zaiSecretProvider`/`backendSecretProvider`) rather than being read inside the package.

8. **Add tests.**
   - Package-level tests for pure logic in the new product.
   - Root app tests under `Tests/RepoPromptTests/` for: adapter-to-controller wiring, model catalog snapshots (option order, defaults, raw values), launch-environment resolution, and any new permission/binding rules.

## Validation

Standard checks for changes that touch the seam:

```bash
# Root build (includes the path-dependency package)
swift build --product RepoPrompt

# Focused suites used during Work Items 1–9
swift test --filter 'ClaudeSDKNDJSONTranslatorTests|ClaudeCompatibleBackendEnvironmentTests|ClaudeNativeApprovalAndResumeTests|ClaudeCompatibleModelCatalogTests|ClaudeCompatiblePluginBridgeTests'

# Package-only iteration
cd Packages/RepoPromptAgentProviders && swift test
```

Add the relevant focused suite before any catalog/codec change, and snapshot model catalogs across `claudeCode`, `claudeCodeGLM`, `kimiCode`, and `customClaudeCompatible` before touching `AgentModelCatalog` branches.

## References

- `Package.swift` — root manifest and product wiring.
- `Packages/RepoPromptAgentProviders/Package.swift` — provider package manifest.
- `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/` — plugin DTOs, codec, translator, prompt delivery, environment builder, catalog, headless arg builder, launch-env resolver.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` — single package import point.
- `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/` — Agent-Mode facade and adapter trio.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift` — provider-neutral runtime contract.
- `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/` — provider-neutral RepoPrompt workflow prompt catalog, metadata, variants, and renderers shared by installs and MCP prompt registration.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift` — `AgentProviderKind` and headless factory.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — `makeClaudeCompatibleNativeController(...)`.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift` — interactive Claude-compatible coordinator.
- SwiftPM package manifest docs: <https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html>
- Xcode local package override workflow: <https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package>
