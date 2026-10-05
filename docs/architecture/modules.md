# Module ownership and allowed edges

`Scripts/modularization/modules.json` is the checked first-party SwiftPM target catalog. Each row names a source root, its permitted **direct first-party** dependencies, and (where applicable) an owning test target. External package-product dependencies remain governed by `Package.swift` and SwiftPM. `make guardrails` compares the catalog with `swift package dump-package`, checks first-party imports against declared edges, and rejects new Swift files placed under a moved family's former app root. CI also builds with SwiftPM's explicit-target-dependency import check set to `error`.

The app target (`RepoPromptApp`) is the composition and product-flow owner, not the destination for new reusable infrastructure. App-free targets must not acquire an edge into `RepoPromptApp`; their owning tests use the module-scoped `make dev-test MODULE=<Target>Tests` path. An exact `FILTER=<SuiteName>` is resolved to that owning target when possible; regex or ambiguous filters retain the aggregate route (ambiguous duplicate suites require an explicit `MODULE`).

| Target family | Ownership | Direction |
| --- | --- | --- |
| `RepoPrompt`, `RepoPromptMCP` | Thin executable entries | App or MCP core respectively |
| `RepoPromptApp` | Product flow, UI, composition | May depend on lower app-free targets |
| `RepoPromptMCPCore`, `RepoPromptDomainRuntime` | Headless CLI and domain runtime | Never depend on app |
| `RepoPromptCodeMapCore`, `RepoPromptRegexCore`, `RepoPromptWorkspaceCore`, `RepoPromptShared` | Narrow reusable cores | Never depend on app |
| `RepoPromptFoundation`, `RepoPromptInstrumentation` | Reusable substrate and diagnostic sink contracts | Never depend on app |
| `RepoPromptProcess` | Headless process and CLI mechanics (no `Bundle.main` or `UserDefaults.standard`) | Foundation and Shared only |
| `RepoPromptSecureStorage` | App-only secure storage | Never linked into MCP CLI |
| `RepoPromptFileSystem` | File reads, FSEvents, ignore matching/compiler, catalog values, injected disk writer | No VCS or app dependency; repository authority and app defaults are supplied by adapters |
| `RepoPromptVCS` | Repository/worktree query values and resolution, GitDiff core, process/clone substrate | FileSystem and lower substrate; intact GitService and app authority orchestration remain app-owned |
| `RepoPromptPersistence` | CodeMap artifacts/catalog/manifests/leases and durable artifact storage | FileSystem, VCS values, CodeMapCore, Shared; no workspace capability or app source-provenance dependency |
| `RepoPromptSettingsCore` | Persisted settings values/document/file store, settings store and global-ignore facet | App-only deployment, with typed events; app policy and notifications remain composition-owned |
| `RepoPromptC`, `CSwiftPCRE2`, `TreeSitterScannerSupport`, `Sparkle` | C/binary support | Leaf support targets |
| `<Module>Tests` | Tests of their corresponding module | Production target plus explicitly cataloged test support |

Each extraction adds its production and test rows to the catalog, records its former app path(s) under `moved_families`, and lowers the matching ratchet baseline. This PR adds `RepoPromptFoundation`, `RepoPromptInstrumentation`, `RepoPromptProcess`, and `RepoPromptSecureStorage`, and extends `RepoPromptRegexCore`; the app remains the implementation owner of instrumentation diagnostics. The placement rule checks newly added paths against the PR merge base, so already-existing app adapters are not mistaken for new module code.

`RepoPromptDomainRuntime/ProviderContent` owns app-free prompt assembly, attachment values and managed storage, image previews, ACP/custom-OpenAI content encoding, and provider result/cleanup values. The app retains model policy, SDK-specific encoders, provider networking, controllers, UI, and composition. Existing app aliases preserve source compatibility; no new target dependency is needed. The Oracle image feature's app-line cost is offset by this extraction, so the combined change fits the existing ceiling without changing the ratchet baseline or headroom.

`app_target_swift_lines` is an advisory reference as of 2026-10-03; report the recorded baseline and unchanged 2,000-line headroom, without treating app line count as a PR blocker or changing its numeric policy. The `app_files_over_2000_lines` and `tests_testable_import_app_files` ratchets remain non-increasing. Index and type-check budgets are separately build-produced CI gates.

Platform adapters preserve the existing app initialization and authorization owners. FileSystem does not discover repository authority, persistence does not grant workspace authority, and settings change events do not replace app notification/model policy. Presets and GitService decomposition are outside this extraction.
