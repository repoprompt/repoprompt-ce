// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Telemetry (Sentry) is resolved deterministically but linked only when explicitly
// requested. The official Developer ID release pipeline sets
// REPOPROMPT_ENABLE_SENTRY=1; local builds use the same gate for intentional
// Sentry testing.
let environment = ProcessInfo.processInfo.environment
let sentryEnabled = environment["REPOPROMPT_ENABLE_SENTRY"] == "1"
let benchmarkTestsEnabled = environment["RPCE_ENABLE_BENCHMARK_TESTS"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "2.3.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.6.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.8.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.6.4"),
    .package(url: "https://github.com/repoprompt/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
    .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", revision: "b7d030cd7453f314c780f5492385f73d704cbd5d"),
    .package(url: "https://github.com/repoprompt/SwiftOpenAI", revision: "1211782eb337e7968124448a20d9260df1952012"),
    .package(path: "Vendor/UniversalCharsetDetection"),
    .package(url: "https://github.com/loopwork-ai/JSONSchema.git", exact: "1.3.0"),
    .package(url: "https://github.com/loopwork-ai/ontology.git", exact: "0.6.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1"),
    .package(path: "Packages/RepoPromptAgentProviders"),
    .package(path: "Packages/RepoPromptPortableRuntime")
]

var repoPromptAppDependencies: [Target.Dependency] = [
    .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptCodeMapCore", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptRegexCore", package: "RepoPromptPortableRuntime"),
    "RepoPromptWorkspaceCore",
    .product(name: "RepoPromptShared", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptC", package: "RepoPromptPortableRuntime"),
    "Sparkle",
    .product(name: "Logging", package: "swift-log"),
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    .product(name: "Markdown", package: "swift-markdown"),
    .product(name: "MCP", package: "swift-sdk"),
    .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
    .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
    .product(name: "UniversalCharsetDetection", package: "UniversalCharsetDetection"),
    .product(name: "Cuchardet", package: "UniversalCharsetDetection"),
    .product(name: "JSONSchema", package: "JSONSchema"),
    .product(name: "Ontology", package: "ontology"),
    .product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders")
]

var repoPromptAppSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .unsafeFlags([
        "-import-objc-header", "\(packageRoot)/Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h",
        "-disable-bridging-pch"
    ])
]

var repoPromptTestDependencies: [Target.Dependency] = [
    "RepoPromptApp",
    .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
    .product(name: "RepoPromptCodeMapCore", package: "RepoPromptPortableRuntime"),
    "RepoPromptMCP",
    .product(name: "RepoPromptShared", package: "RepoPromptPortableRuntime"),
    .product(name: "Markdown", package: "swift-markdown")
]

var repoPromptTestSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug))
]

if sentryEnabled {
    let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")
    repoPromptAppDependencies.append(sentryDependency)
    repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
    repoPromptTestDependencies.append(sentryDependency)
    repoPromptTestSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
}

if benchmarkTestsEnabled {
    repoPromptTestSwiftSettings.append(.define("RPCE_BENCHMARK_TESTS"))
}

let package = Package(
    name: "RepoPromptCE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RepoPrompt", targets: ["RepoPrompt"]),
        .executable(name: "repoprompt-mcp", targets: ["RepoPromptMCP"])
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "RepoPrompt",
            dependencies: ["RepoPromptApp"],
            path: "Sources/RepoPromptExecutable"
        ),
        .target(
            name: "RepoPromptWorkspaceCore",
            path: "Sources/RepoPromptWorkspaceCore"
        ),
        .target(
            name: "RepoPromptApp",
            dependencies: repoPromptAppDependencies,
            path: "Sources/RepoPrompt",
            swiftSettings: repoPromptAppSwiftSettings
        ),
        .executableTarget(
            name: "RepoPromptMCP",
            dependencies: [
                .product(name: "RepoPromptShared", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptCodeMapCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptC", package: "RepoPromptPortableRuntime"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Sources/RepoPromptMCP",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .testTarget(
            name: "RepoPromptWorkspaceCoreTests",
            dependencies: ["RepoPromptWorkspaceCore"],
            path: "Tests/RepoPromptWorkspaceCoreTests"
        ),
        .testTarget(
            name: "RepoPromptTests",
            dependencies: repoPromptTestDependencies,
            path: "Tests/RepoPromptTests",
            swiftSettings: repoPromptTestSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
