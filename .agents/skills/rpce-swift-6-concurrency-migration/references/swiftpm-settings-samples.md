# SwiftPM concurrency settings samples

Use this file when changing `Package.swift` or the provider manifest. These are repository-local examples, not substitutes for checking the active compiler invocation.

## Contents

- Settings axes
- Reusable SwiftPM settings
- Stage A: complete checking in Swift 5 mode
- Stage B: mixed target language modes
- Stage C: package completion
- Stage D: Swift 6.2 semantics
- Xcode equivalents
- Verification checklist

## Settings axes

Do not collapse these independent controls:

| Axis | SwiftPM 6.2 spelling | Scope | What it changes |
|---|---|---|---|
| Tools version | `// swift-tools-version: 6.2` | Manifest API | Which `PackageDescription` APIs are available |
| Package language compatibility/default | `swiftLanguageModes: [...]` | Package | Package language-mode declaration and default selection |
| Target language mode | `.swiftLanguageMode(.v5/.v6)` | Target | The `-swift-version` passed for that target |
| Complete checking in Swift 5 | `.enableExperimentalFeature("StrictConcurrency")` | Target | Diagnostic strictness without the full Swift 6 language-mode switch |
| Default actor isolation | `.defaultIsolation(MainActor.self)` | Target | Inference for otherwise-unannotated declarations |
| Caller-actor async semantics | `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` | Target | Whether nonisolated async calls stay on the caller's actor by default |
| Isolated-conformance inference | `.enableUpcomingFeature("InferIsolatedConformances")` | Target | Whether eligible isolated conformances are inferred |

The active compiler is the final authority. Record `swift --version` and inspect the actual build command before treating a setting as active.

## Reusable SwiftPM settings

Keep settings named by semantic effect so a review can see which gate is moving:

```swift
import PackageDescription

let swift5CompleteChecking: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableExperimentalFeature("StrictConcurrency"),
]

let swift6LanguageMode: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let callerActorAsyncSemantics: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let inferredIsolatedConformances: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
]
```

Do not apply every array at once. Each array represents a separate review and rollback gate.

## Stage A: complete checking in Swift 5 mode

Use this to expose diagnostics in a leaf target without changing Swift 6 execution semantics:

```swift
.target(
    name: "RepoPromptWorkspaceCore",
    path: "Sources/RepoPromptWorkspaceCore",
    swiftSettings: [
        .swiftLanguageMode(.v5),
        .enableExperimentalFeature("StrictConcurrency"),
    ]
)
```

Expected properties:

- Swift 5 language behavior remains selected for this target.
- Complete concurrency diagnostics are surfaced early.
- Default actor isolation and the two Swift 6.2 upcoming features remain unchanged.
- A diagnostic fix in this stage should not rely on caller-actor behavior that is not enabled yet.

For `RepoPromptShared` or a provider target, use the same shape but preserve existing conditional defines.

## Stage B: prove mixed target language modes

Before using this pattern in production, verify it with the active toolchain and record the compiler flags. A minimal manifest probe can make every target's language mode explicit:

```swift
let package = Package(
    name: "LanguageModeProbe",
    targets: [
        .target(
            name: "LeafV6",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ConsumerV5",
            dependencies: ["LeafV6"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5, .v6]
)
```

Verification evidence must answer:

1. Does the manifest parse under the selected Xcode/SwiftPM?
2. Does `LeafV6` receive `-swift-version 6`?
3. Does `ConsumerV5` receive `-swift-version 5` and complete checking?
4. Do module-boundary diagnostics appear at the consumer, the producer, or both?
5. Does the repository's generated Xcode workspace preserve the intended settings?

If the active toolchain rejects or ignores mixed target modes, retain target-level complete checking and use a package-wide language-mode flip only after every target reaches its gate.

## Stage C: complete a package

After every Swift target in the package passes Swift 6 checking, simplify the manifest:

```swift
let package = Package(
    name: "RepoPromptCE",
    // products, dependencies, and targets omitted
    swiftLanguageModes: [.v6]
)
```

Then remove redundant per-target `.swiftLanguageMode(.v6)` entries only when the package default is verified. Keep target-local settings whose semantics remain intentional, such as default isolation or an upcoming feature.

Package acceptance requires:

- all production and test targets compile;
- public/package API sendability changes are reviewed;
- escape hatches have invariants and audit conditions;
- root or provider package tests pass through conductor;
- mixed-language dependency diagnostics are resolved or documented.

## Stage D: adopt Swift 6.2 semantics separately

### Caller-actor execution

```swift
.target(
    name: "RepoPromptWorkspaceCore",
    path: "Sources/RepoPromptWorkspaceCore",
    swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
)
```

Before enabling it, inventory nonisolated async functions that perform blocking or CPU-heavy work. The setting can keep that work on the caller's actor.

### Isolated-conformance inference

```swift
.target(
    name: "RepoPrompt",
    dependencies: ["RepoPromptApp"],
    path: "Sources/RepoPromptExecutable",
    swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
)
```

Enable only after reviewing protocol use sites. An inferred isolated conformance is not usable from arbitrary nonisolated generic code.

### Default MainActor isolation

```swift
.executableTarget(
    name: "RepoPrompt",
    dependencies: ["RepoPromptApp"],
    path: "Sources/RepoPromptExecutable",
    swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
    ]
)
```

This shape is suitable only if the target is wholly main-actor owned. Do not apply it to the mixed `RepoPromptApp`, MCP, workspace core, shared protocol, CodeMap core, regex core, or provider targets merely because the shipped product is a macOS app.

### A deliberately bad bundle

Do not hide four semantic changes in one manifest edit:

```swift
// Avoid: impossible to attribute diagnostics or runtime changes.
swiftSettings: [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency"),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]
```

Advance one gate at a time unless a target is already diagnostic-free and the PR records independent evidence and rollback points for each setting.

## Xcode equivalents

| Decision | Xcode/compiler setting |
|---|---|
| Swift 6 mode | `SWIFT_VERSION = 6` / `-swift-version 6` |
| Complete checking | `SWIFT_STRICT_CONCURRENCY = complete` / `-strict-concurrency=complete` |
| Default MainActor | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` / `-default-isolation MainActor` |
| Caller-actor semantics | `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES` |
| Isolated-conformance inference | `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = YES` |

`SWIFT_APPROACHABLE_CONCURRENCY` is an Xcode umbrella setting. SwiftPM uses the individual APIs above; do not invent an `ApproachableConcurrency` feature name.

## Verification checklist

For each settings edit:

1. Record Xcode, Swift, SDK, package revision, target, and previous settings.
2. Run the smallest conductor product build that compiles the target.
3. Capture one compiler invocation or diagnostic proving the setting applied.
4. Run the focused behavioral tests for the touched isolation/lifetime contract.
5. Update diagnostic counts and the escape-hatch ledger.
6. Run package-level gates only at the phase boundary.
7. Never infer successful adoption solely from a clean incremental build.
