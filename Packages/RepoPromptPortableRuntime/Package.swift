// swift-tools-version: 6.2
import PackageDescription

let swift6LanguageMode: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "RepoPromptPortableRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RepoPromptRuntimeModel", targets: ["RepoPromptRuntimeModel"]),
        .library(name: "RepoPromptAuthorityAPI", targets: ["RepoPromptAuthorityAPI"]),
        .library(name: "RepoPromptShared", targets: ["RepoPromptShared"]),
        .library(name: "RepoPromptAgentRuntimeCore", targets: ["RepoPromptAgentRuntimeCore"]),
        .library(name: "RepoPromptWorkspaceRuntimeCore", targets: ["RepoPromptWorkspaceRuntimeCore"]),
        .library(name: "RepoPromptDomainRuntime", targets: ["RepoPromptDomainRuntime"]),
        .library(name: "RepoPromptHeadlessRuntime", targets: ["RepoPromptHeadlessRuntime"]),
        .library(name: "RepoPromptCodeMapCore", targets: ["RepoPromptCodeMapCore"]),
        .library(name: "RepoPromptRegexCore", targets: ["RepoPromptRegexCore"]),
        .library(name: "RepoPromptC", targets: ["RepoPromptC"]),
        .library(name: "RepoPromptLinuxSupport", targets: ["RepoPromptLinuxSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", "1.6.3" ..< "2.0.0"),
        .package(url: "https://github.com/repoprompt/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
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
        .package(url: "https://github.com/tree-sitter/tree-sitter-php.git", exact: "0.24.2")
    ],
    targets: [
        .target(
            name: "RepoPromptRuntimeModel",
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptAuthorityAPI",
            dependencies: ["RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptShared",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptAgentRuntimeCore",
            dependencies: ["RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptWorkspaceRuntimeCore",
            dependencies: ["RepoPromptRuntimeModel", "RepoPromptShared"],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptDomainRuntime",
            dependencies: [
                "RepoPromptShared",
                "RepoPromptRuntimeModel",
                "RepoPromptC",
                "RepoPromptCodeMapCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptHeadlessRuntime",
            dependencies: [
                "RepoPromptRuntimeModel",
                "RepoPromptAuthorityAPI",
                "RepoPromptShared",
                "RepoPromptAgentRuntimeCore",
                "RepoPromptWorkspaceRuntimeCore",
                "RepoPromptDomainRuntime"
            ],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptLinuxSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CSwiftPCRE2",
            exclude: [
                "deps/sljit/sljit_src/sljitNativeARM_64.c",
                "deps/sljit/sljit_src/sljitSerialize.c",
                "deps/sljit/sljit_src/sljitUtils.c",
                "deps/sljit/sljit_src/sljitNativeX86_common.c",
                "deps/sljit/sljit_src/sljitNativeX86_64.c",
                "deps/sljit/sljit_src/sljitNativeX86_32.c",
                "deps/sljit/sljit_src/allocator_src/sljitWXExecAllocatorPosix.c",
                "deps/sljit/sljit_src/allocator_src/sljitProtExecAllocatorPosix.c",
                "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorPosix.c",
                "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorCore.c",
                "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorApple.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .define("PCRE2_CODE_UNIT_WIDTH", to: "8"),
                .define("HAVE_CONFIG_H")
            ]
        ),
        .target(
            name: "RepoPromptC",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterScannerSupport",
            sources: ["src/javascript/scanner.c", "src/python/scanner.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "RepoPromptRegexCore",
            dependencies: ["CSwiftPCRE2"],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptCodeMapCore",
            dependencies: [
                "RepoPromptRegexCore",
                "TreeSitterScannerSupport",
                .product(name: "Crypto", package: "swift-crypto"),
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
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "RepoPromptRuntimeModelTests",
            dependencies: ["RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptAuthorityAPITests",
            dependencies: ["RepoPromptAuthorityAPI", "RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptAgentRuntimeCoreTests",
            dependencies: ["RepoPromptAgentRuntimeCore", "RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptWorkspaceRuntimeCoreTests",
            dependencies: ["RepoPromptWorkspaceRuntimeCore", "RepoPromptRuntimeModel"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptHeadlessRuntimeTests",
            dependencies: ["RepoPromptHeadlessRuntime", "RepoPromptRuntimeModel", "RepoPromptAuthorityAPI"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptPortableFixtureTests",
            dependencies: ["RepoPromptAgentRuntimeCore", "RepoPromptRuntimeModel"],
            path: "Tests/Fixtures",
            sources: ["RepoPromptPortableFixtureTests.swift"],
            resources: [.copy("AgentParity")],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptDomainRuntimeTests",
            dependencies: [
                "RepoPromptDomainRuntime",
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptRegexCoreTests",
            dependencies: ["RepoPromptRegexCore"],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptCodeMapCoreTests",
            dependencies: ["RepoPromptCodeMapCore"],
            resources: [
                .copy("Fixtures"),
                .copy("Goldens")
            ],
            swiftSettings: swift6LanguageMode
        )
    ],
    swiftLanguageModes: [.v5]
)
