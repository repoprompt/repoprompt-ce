# ADR-001: Target graph and CE C-symbol namespace

- **Status:** Accepted
- **Date:** 2026-06-21
- **Decision owners:** Core isolation overall lead and package/control-plane owner
- **Source revisions:** `8e42951159c9f1d6973a4538a309908baacdb371` and reviewed reference `21b5603f5a333454aee899dd39ff38d860a5b716`

## Context

The current package has executable products `RepoPrompt` and `repoprompt-mcp`,
targets `RepoPrompt`, `RepoPromptMCP`, `RepoPromptShared`, `RepoPromptC`,
`CSwiftPCRE2`, `TreeSitterScannerSupport`, `Sparkle`, and `RepoPromptTests`.
The app target directly owns every syntax, regex, charset, UI, provider, and
application dependency through a target-wide bridging header.

The reference feature graph put charset decoding in Core and made POSIX support
depend on `RepoPromptC`. The current execution plan supersedes both choices:
charset is a concrete CoreMacOS implementation detail, while POSIX support is a
narrow system API boundary.

## Decision

### Final direct target/product edges

| Target | Allowed direct dependencies |
| --- | --- |
| `RepoPromptSyntaxCBridge` | local `TreeSitterScannerSupport`; products `TreeSitterC`, `TreeSitterDart`, `TreeSitterGo`, `TreeSitterJava`, `TreeSitterJavaScript`, `TreeSitterPython`, `TreeSitterRust`, `TreeSitterTypeScript`, `TreeSitterRuby`, `TreeSitterSwift`, `TreeSitterCSharp`, `TreeSitterCPP`, `TreeSitterPHP` |
| `RepoPromptCore` | local `RepoPromptC`, `CSwiftPCRE2`, `RepoPromptSyntaxCBridge`; product `SwiftTreeSitter`; system modules Foundation, Dispatch, CryptoKit |
| `RepoPromptPOSIXSupport` | system C/POSIX APIs only; Foundation, Darwin and `Darwin.POSIX.fcntl` where required; no app, Core, `RepoPromptC`, or third-party product edge |
| `RepoPromptCoreMacOS` | `RepoPromptCore`, `RepoPromptPOSIXSupport`; products `UniversalCharsetDetection` and `Cuchardet`; Foundation, Dispatch, CryptoKit, CoreFoundation, CoreServices, Darwin, Security |
| `RepoPrompt` | `RepoPromptShared`, `RepoPromptCore`, `RepoPromptCoreMacOS`, `Sparkle`; products `Logging`, `KeyboardShortcuts`, `MarkdownUI`, `Markdown`, `SwiftyJSON`, `MCP`, `SwiftAnthropic`, `SwiftOpenAI`, `Neon`, `JSONSchema`, `Ontology`, `RepoPromptClaudeCompatibleProvider`; `SwiftTreeSitter` only for documented UI highlighting that remains after extraction |
| `RepoPromptMCP` | `RepoPromptShared`, `RepoPromptPOSIXSupport`; products `Logging`, `MCP`, `ServiceLifecycle`, `SystemPackage` |
| `RepoPromptHeadless` | `RepoPromptShared`, `RepoPromptCore`, `RepoPromptCoreMacOS`, `RepoPromptPOSIXSupport`; product `Logging` only; no app or `RepoPromptMCP` edge |
| Dedicated tests | owning production target; root integration may import app/MCP/Core targets; fixture/support exceptions must be entered in the migration ledger |

The only new executable product is `repoprompt-headless`. The five production
target names and seven test-ledger prefixes are frozen in the execution plan.
Phase 1 declares a test target only when its first meaningful executable test exists.

### Acyclicity

A topological order is:

1. `RepoPromptShared`, `RepoPromptC`, `CSwiftPCRE2`,
   `TreeSitterScannerSupport`, external products;
2. `RepoPromptSyntaxCBridge` and `RepoPromptPOSIXSupport`;
3. `RepoPromptCore`;
4. `RepoPromptCoreMacOS`;
5. `RepoPrompt`, `RepoPromptMCP`, and `RepoPromptHeadless`;
6. test targets.

No reverse edge is allowed. Core never imports RepoPrompt, CoreMacOS, POSIX
implementation modules, AppKit, SwiftUI, Security, Darwin, CoreServices, OSLog,
or `os`.

### C symbols

`rpce_` is reserved as the prefix for every new CE-defined C function, global,
or externally visible wrapper symbol introduced by the isolation work. Swift-only
helpers do not require a C prefix. Existing `repo_*` symbols remain owned by
`RepoPromptC`. Upstream `tree_sitter_*` symbols retain their upstream names and
must have exactly one linked implementation; `RepoPromptSyntaxCBridge` declares
and links them but does not wrap or duplicate them unless a future ADR names a
specific necessity.

## Consequences

- The graph differs deliberately from the old feature manifest.
- UniversalCharsetDetection and Cuchardet cannot leak into neutral Core.
- `RepoPromptPOSIXSupport` cannot become a second generic C utility bucket.
- Phase 1 must add compiler/source guards for these edges and the `rpce_`
  namespace before Phase 3 introduces wrappers.
- Any additional direct product edge requires a superseding ADR and an updated
  migration-ledger row before code lands.
