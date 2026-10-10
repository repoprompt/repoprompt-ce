// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Telemetry (Sentry) is resolved deterministically but linked only when explicitly
// requested. The official Developer ID release pipeline sets
// REPOPROMPT_ENABLE_SENTRY=1; local builds use the same gate for intentional
// Sentry testing.
let environment = ProcessInfo.processInfo.environment
let sentryEnabled = environment["REPOPROMPT_ENABLE_SENTRY"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "2.3.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.6.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.8.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.6.4"),
    .package(url: "https://github.com/repoprompt/swift-sdk.git", revision: "5716de85a976a8f70dedc9cb000e50aaa0d8cc5b"),
    // RepoPromptApp and RepoPromptCodeMapCore share this customized wrapper/runtime graph.
    .package(
        url: "https://github.com/repoprompt/swift-tree-sitter.git",
        revision: "a778ef4fb7f0d3ad00185f42ce83c688373c4361"
    ),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
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
    .package(url: "https://github.com/repoprompt/SwiftOpenAI", revision: "1211782eb337e7968124448a20d9260df1952012"),
    .package(path: "Vendor/UniversalCharsetDetection"),
    .package(url: "https://github.com/loopwork-ai/JSONSchema.git", exact: "1.3.0"),
    .package(url: "https://github.com/loopwork-ai/ontology.git", exact: "0.6.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1"),
    .package(path: "Packages/RepoPromptAgentProviders")
]

var repoPromptAppDependencies: [Target.Dependency] = [
    "RepoPromptDomainRuntime",
    "RepoPromptFoundation",
    "RepoPromptProcess",
    "RepoPromptInstrumentation",
    "RepoPromptSecureStorage",
    "RepoPromptFileSystem",
    "RepoPromptVCS",
    "RepoPromptPersistence",
    "RepoPromptSettingsCore",
    "RepoPromptProviderQuota",
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
    .enableUpcomingFeature("BareSlashRegexLiterals")
]

var repoPromptSettingsCoreSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug))
]

var repoPromptTestDependencies: [Target.Dependency] = [
    "RepoPromptApp",
    "RepoPromptFoundation",
    "RepoPromptProcess",
    "RepoPromptInstrumentation",
    "RepoPromptSecureStorage",
    "RepoPromptFileSystem",
    "RepoPromptVCS",
    "RepoPromptPersistence",
    "RepoPromptSettingsCore",
    "RepoPromptProviderQuota",
    "RepoPromptDomainRuntime",
    "RepoPromptCodeMapCore",
    "RepoPromptMCPCore",
    "RepoPromptShared",
    "RepoPromptTestSupport",
    "RepoPromptWorkspaceCore",
    .product(name: "Markdown", package: "swift-markdown")
]

var repoPromptTestSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug))
]

var repoPromptCodeMapTestSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug))
]

if sentryEnabled {
    let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")
    repoPromptAppDependencies.append(sentryDependency)
    repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
    repoPromptSettingsCoreSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
    repoPromptTestDependencies.append(sentryDependency)
    repoPromptTestSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
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
            name: "RepoPromptProviderQuota",
            dependencies: [],
            path: "Sources/RepoPromptProviderQuota",
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptProviderQuotaTests",
            dependencies: ["RepoPromptProviderQuota"],
            path: "Tests/RepoPromptProviderQuotaTests",
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptDomainRuntime",
            dependencies: [
                "RepoPromptShared",
                "RepoPromptWorkspaceCore",
                "RepoPromptC",
                "RepoPromptCodeMapCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/RepoPromptDomainRuntime",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptFoundation",
            dependencies: [
                "RepoPromptWorkspaceCore",
                "RepoPromptCodeMapCore"
            ],
            path: "Sources/RepoPromptFoundation",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptProcess",
            dependencies: ["RepoPromptFoundation", "RepoPromptShared"],
            path: "Sources/RepoPromptProcess",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "RepoPromptFileSystemTests",
            dependencies: ["RepoPromptFileSystem"],
            path: "Tests/RepoPromptFileSystemTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptFileSystem",
            dependencies: ["RepoPromptFoundation", "RepoPromptDomainRuntime", "RepoPromptWorkspaceCore", "RepoPromptC", .product(name: "UniversalCharsetDetection", package: "UniversalCharsetDetection"), .product(name: "Cuchardet", package: "UniversalCharsetDetection")],
            path: "Sources/RepoPromptFileSystem",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptVCSTests",
            dependencies: ["RepoPromptVCS"],
            path: "Tests/RepoPromptVCSTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptVCS",
            dependencies: ["RepoPromptFoundation", "RepoPromptProcess", "RepoPromptInstrumentation", "RepoPromptDomainRuntime", "RepoPromptFileSystem", "RepoPromptWorkspaceCore"],
            path: "Sources/RepoPromptVCS",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptPersistenceTests",
            dependencies: ["RepoPromptPersistence", "RepoPromptCodeMapCore", "RepoPromptFoundation", "RepoPromptFileSystem", "RepoPromptVCS"],
            path: "Tests/RepoPromptPersistenceTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptPersistence",
            dependencies: ["RepoPromptCodeMapCore", "RepoPromptFileSystem", "RepoPromptVCS", "RepoPromptShared"],
            path: "Sources/RepoPromptPersistence",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptSettingsCoreTests",
            dependencies: ["RepoPromptSettingsCore", "RepoPromptProviderQuota"],
            path: "Tests/RepoPromptSettingsCoreTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptSettingsCore",
            dependencies: ["RepoPromptFoundation", "RepoPromptDomainRuntime", "RepoPromptProviderQuota", "RepoPromptShared"],
            path: "Sources/RepoPromptSettingsCore",
            swiftSettings: repoPromptSettingsCoreSwiftSettings
        ),
        .target(
            name: "RepoPromptSecureStorage",
            path: "Sources/RepoPromptSecureStorage",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptInstrumentation",
            dependencies: ["RepoPromptFoundation", "RepoPromptShared"],
            path: "Sources/RepoPromptInstrumentation",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
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
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
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
            dependencies: ["RepoPromptMCPCore", "RepoPromptShared", "RepoPromptDomainRuntime", .product(name: "Logging", package: "swift-log"), .product(name: "MCP", package: "swift-sdk"), .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"), .product(name: "SystemPackage", package: "swift-system")],
            path: "Sources/RepoPromptMCP",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptMCPCore",
            dependencies: ["RepoPromptShared", "RepoPromptDomainRuntime", "RepoPromptCodeMapCore", "RepoPromptVCS", "RepoPromptC", .product(name: "Logging", package: "swift-log"), .product(name: "MCP", package: "swift-sdk"), .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"), .product(name: "SystemPackage", package: "swift-system")],
            path: "Sources/RepoPromptMCPCore",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptShared",
            path: "Sources/RepoPromptShared",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(name: "CSwiftPCRE2", path: "Sources/CSwiftPCRE2", exclude: ["deps/sljit/sljit_src/sljitNativeARM_64.c", "deps/sljit/sljit_src/sljitSerialize.c", "deps/sljit/sljit_src/sljitUtils.c", "deps/sljit/sljit_src/sljitNativeX86_common.c", "deps/sljit/sljit_src/sljitNativeX86_64.c", "deps/sljit/sljit_src/sljitNativeX86_32.c", "deps/sljit/sljit_src/allocator_src/sljitWXExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitProtExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorCore.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorApple.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("include"), .headerSearchPath("src"), .define("PCRE2_CODE_UNIT_WIDTH", to: "8"), .define("HAVE_CONFIG_H")]),
        .target(name: "RepoPromptC", path: "Sources/RepoPromptC", publicHeadersPath: "include", cSettings: [.headerSearchPath("include")]),
        // Exact-snapshot scanner ABI fallback for the JavaScript/Python manifests, whose
        // FileManager source probe evaluates false in this root package graph.
        .target(name: "TreeSitterScannerSupport", path: "Sources/TreeSitterScannerSupport", sources: ["src/javascript/scanner.c", "src/python/scanner.c"], publicHeadersPath: "include"),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .testTarget(
            name: "RepoPromptDomainRuntimeTests",
            dependencies: [
                "RepoPromptDomainRuntime",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/RepoPromptDomainRuntimeTests",
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptMCPCoreTests",
            dependencies: [
                "RepoPromptMCPCore",
                "RepoPromptDomainRuntime",
                "RepoPromptShared",
                "RepoPromptTestSupport",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/RepoPromptMCPCoreTests"
        ),
        // Test-only helpers shared across test targets. Production targets must never depend on it.
        .target(
            name: "RepoPromptTestSupport",
            path: "Tests/RepoPromptTestSupport"
        ),
        .testTarget(
            name: "RepoPromptFoundationTests",
            dependencies: ["RepoPromptFoundation"],
            path: "Tests/RepoPromptFoundationTests",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "RepoPromptProcessTests",
            dependencies: ["RepoPromptProcess"],
            path: "Tests/RepoPromptProcessTests",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "RepoPromptSecureStorageTests",
            dependencies: ["RepoPromptSecureStorage", "RepoPromptTestSupport"],
            path: "Tests/RepoPromptSecureStorageTests",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "RepoPromptInstrumentationTests",
            dependencies: ["RepoPromptInstrumentation", "RepoPromptTestSupport"],
            path: "Tests/RepoPromptInstrumentationTests",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
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
            swiftSettings: swift6LanguageMode + repoPromptCodeMapTestSwiftSettings
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
