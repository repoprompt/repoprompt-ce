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
    .package(url: "https://github.com/provencher/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
    // RepoPromptApp and Neon share this exact wrapper/runtime graph.
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.10.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
    .package(url: "https://github.com/UserNobody14/tree-sitter-dart", revision: "be07cf7118d3dba06236a3f19541685a68209934"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
    .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp.git", exact: "0.23.5"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-php.git", exact: "0.24.2"),
    .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", revision: "b7d030cd7453f314c780f5492385f73d704cbd5d"),
    .package(url: "https://github.com/provencher/SwiftOpenAI", revision: "1211782eb337e7968124448a20d9260df1952012"),
    // Released Neon versions predate SwiftTreeSitter 0.10; retain this exact compatible revision.
    .package(url: "https://github.com/ChimeHQ/Neon.git", revision: "07a325403534f4759c814aff0a58ac69144a524c"),
    .package(path: "Vendor/UniversalCharsetDetection"),
    .package(url: "https://github.com/loopwork-ai/JSONSchema.git", exact: "1.3.0"),
    .package(url: "https://github.com/loopwork-ai/ontology.git", exact: "0.6.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1"),
    .package(path: "Packages/RepoPromptAgentProviders")
]

var repoPromptAppDependencies: [Target.Dependency] = [
    "RepoPromptCodeMapCore",
    "RepoPromptRegexCore",
    "RepoPromptWorkspaceCore",
    "RepoPromptShared",
    "RepoPromptC", "CSwiftPCRE2",
    "Sparkle",
    .product(name: "Logging", package: "swift-log"),
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    .product(name: "Markdown", package: "swift-markdown"),
    .product(name: "MCP", package: "swift-sdk"),
    .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
    .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
    .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
    .product(name: "Neon", package: "Neon"),
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
    "RepoPromptCodeMapCore",
    "RepoPromptMCP",
    "RepoPromptShared"
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

let swift6LanguageMode: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

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
            name: "RepoPromptRegexCore",
            dependencies: ["CSwiftPCRE2"],
            path: "Sources/RepoPromptRegexCore",
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptCodeMapCore",
            dependencies: [
                "RepoPromptRegexCore",
                "TreeSitterScannerSupport",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterDart", package: "tree-sitter-dart"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterPHP", package: "tree-sitter-php")
            ],
            path: "Sources/RepoPromptCodeMapCore",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptApp",
            dependencies: repoPromptAppDependencies,
            path: "Sources/RepoPrompt",
            swiftSettings: repoPromptAppSwiftSettings
        ),
        .executableTarget(
            name: "RepoPromptMCP",
            dependencies: ["RepoPromptShared", .product(name: "Logging", package: "swift-log"), .product(name: "MCP", package: "swift-sdk"), .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"), .product(name: "SystemPackage", package: "swift-system")],
            path: "Sources/RepoPromptMCP",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptShared",
            path: "Sources/RepoPromptShared",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(name: "CSwiftPCRE2", path: "Sources/CSwiftPCRE2", exclude: ["deps/sljit/sljit_src/sljitNativeARM_64.c", "deps/sljit/sljit_src/sljitSerialize.c", "deps/sljit/sljit_src/sljitUtils.c", "deps/sljit/sljit_src/sljitNativeX86_common.c", "deps/sljit/sljit_src/sljitNativeX86_64.c", "deps/sljit/sljit_src/sljitNativeX86_32.c", "deps/sljit/sljit_src/allocator_src/sljitWXExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitProtExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorCore.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorApple.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("include"), .headerSearchPath("src"), .define("PCRE2_CODE_UNIT_WIDTH", to: "8"), .define("HAVE_CONFIG_H")]),
        .target(name: "RepoPromptC", path: "Sources/RepoPromptC", publicHeadersPath: "include", cSettings: [.headerSearchPath("include")]),
        // Exact-snapshot scanner ABI fallback for the JavaScript/Python manifests, whose
        // FileManager source probe evaluates false in this root package graph.
        .target(name: "TreeSitterScannerSupport", path: "Sources/TreeSitterScannerSupport", sources: ["src/javascript/scanner.c", "src/python/scanner.c"], publicHeadersPath: "include"),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .testTarget(
            name: "RepoPromptWorkspaceCoreTests",
            dependencies: ["RepoPromptWorkspaceCore"],
            path: "Tests/RepoPromptWorkspaceCoreTests"
        ),
        .testTarget(
            name: "RepoPromptRegexCoreTests",
            dependencies: ["RepoPromptRegexCore"],
            path: "Tests/RepoPromptRegexCoreTests",
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptCodeMapCoreTests",
            dependencies: ["RepoPromptCodeMapCore"],
            path: "Tests/RepoPromptCodeMapCoreTests",
            resources: [
                .copy("Fixtures"),
                .copy("Goldens")
            ],
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
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
