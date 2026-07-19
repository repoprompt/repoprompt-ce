# Official Swift 6.2 concurrency guidance

Use these primary sources as the semantic authority. Community skills can supply useful workflows, but they do not override the compiler, accepted Swift Evolution proposals, or the Swift migration guide.

## Feature map

| Decision | Xcode/compiler setting | SwiftPM tools 6.2 | Meaning |
|---|---|---|---|
| Swift 6 language mode | `SWIFT_VERSION = 6` / `-swift-version 6` | Package `swiftLanguageModes: [.v6]`; target `.swiftLanguageMode(.v6)` | Enables Swift 6 language rules and complete data-race safety enforcement. Verify target-local mixed-mode behavior from actual compiler flags before using it for phased adoption. |
| Stage strict checking in Swift 5 mode | `SWIFT_STRICT_CONCURRENCY = complete` | Target `.enableExperimentalFeature("StrictConcurrency")` | Surfaces complete concurrency checking before a target or package language-mode switch. Verify the active compiler accepts and applies the setting. |
| Default main-actor isolation | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` / `-default-isolation MainActor` | Target `.defaultIsolation(MainActor.self)` | Infers `@MainActor` for eligible unannotated declarations. Suitable only where main-actor ownership is the correct target design. |
| Caller-actor async execution | `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES` | Target `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` | Nonisolated async functions run on the caller's actor by default. This is a semantic change, not merely a warning toggle. |
| Isolated-conformance inference | `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = YES` | Target `.enableUpcomingFeature("InferIsolatedConformances")` | Infers isolated conformances where the language rules allow. Explicit syntax expresses the contract directly. |
| Explicit off-actor work | `@concurrent` on an async declaration | Swift 6.2 source feature | Explicitly switches work off an actor onto the global concurrent executor. Crossing values must satisfy sendability or region-isolation rules. |

Xcode's `SWIFT_APPROACHABLE_CONCURRENCY = YES` is an umbrella build setting. SwiftPM uses the individual settings; do not invent an `ApproachableConcurrency` package API.

`SwiftSetting.swiftLanguageMode` is available to manifests using PackageDescription 6.0 or newer. Its presence does not prove that this repository's active SwiftPM, generated Xcode workspace, and dependency graph preserve a desired mixed-mode rollout; run the probe in `swiftpm-settings-samples.md` and inspect compiler invocations.

## Migration implications

- Compiler version, tools version, and language mode are different axes.
- `async` describes suspension; it does not by itself promise background execution.
- Default `MainActor` isolation and caller-actor async execution are independent choices.
- Enabling `NonisolatedNonsendingByDefault` can move formerly off-actor work back onto the caller's actor. Profile before adding `@concurrent`.
- Isolated conformances restrict where the conformance can be used.
- Prefer static actor contracts over widespread `MainActor.run` or runtime isolation assertions.
- Use migration fix-its as input for review, not proof that runtime ownership is correct.

## Materialized local examples

- `swiftpm-settings-samples.md` contains staged root/provider manifest shapes, independent settings axes, and verification gates.
- `swift-6-2-semantics-samples.md` contains caller-actor, `@concurrent`, default-isolation, isolated-conformance, and task-inheritance examples.
- The bounded-fix skill's `references/` directory contains repair samples for isolation/sendability, task lifetime/continuations, and synchronization/interoperability.

Use these local files for routine work. Return to the primary sources only for unresolved semantic ambiguity or a newer toolchain.

## Primary sources

- [Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/)
- [Swift 6 migration guide](https://www.swift.org/migration/)
- [Migration strategy](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/)
- [Data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)
- [Incremental adoption](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)
- [SE-0461: caller-actor execution and `@concurrent`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [Compiler documentation: `NonisolatedNonsendingByDefault`](https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/)
- [SE-0466: default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [SwiftPM `swiftLanguageMode`](https://docs.swift.org/swiftpm/documentation/packagedescription/swiftsetting/swiftlanguagemode(_:_:))
- [SwiftPM `defaultIsolation`](https://docs.swift.org/swiftpm/documentation/packagedescription/swiftsetting/defaultisolation(_:_:))
- [SE-0470: isolated conformances](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md)
- [Swift concurrency language guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [WWDC25: Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/)

## Xcode provenance

The local baseline inspected while creating this skill was Xcode 26.3 build 17C529 with Apple Swift 6.2.4. Its bundled `Swift-Concurrency-Updates.md` has SHA-256 `0fbd5c2b5dd87710efd68e73c34476749275363bd2b7ad569039e590c3f3c7ce`.

Research on 2026-07-18 found that Xcode 27 beta 3 (build 27A5218g) ships Swift 6.4 and Apple-authored exportable skills, while the inspected inventory snapshot did not include a dedicated general Swift-concurrency migration skill. This was not a direct local export, so reverify against the installed Xcode build.

Select Xcode 27 explicitly and use an absolute output path when exporting:

```bash
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" \
  xcrun agent skills export --output-dir "$HOME/xcode-27-skills"
```

See [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) and [Apple's agent customization documentation](https://developer.apple.com/documentation/Xcode/extending-and-customizing-agents). Do not vendor a mirror unless its provenance and redistribution terms have been verified.
