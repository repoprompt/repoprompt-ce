// swift-tools-version: 6.2
import PackageDescription

let swift6LanguageMode: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "RepoPromptServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RepoPromptServer", targets: ["RepoPromptServerExecutable"]),
        .executable(name: "repoprompt-mcp-headless-runtime", targets: ["RepoPromptMCPHeadlessExecutable"])
    ],
    dependencies: [
        .package(path: "../RepoPromptPortableRuntime"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.14.0"),
        .package(url: "https://github.com/repoprompt/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
        .package(url: "https://github.com/vapor/sqlite-nio.git", exact: "1.13.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.22.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.34.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.5.1")
    ],
    targets: [
        .target(
            name: "RepoPromptServiceProtocol",
            dependencies: [
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptServerOperations",
            dependencies: [
                .product(name: "RepoPromptCodeMapCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptWorkspaceRuntimeCore", package: "RepoPromptPortableRuntime")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptServicePersistence",
            dependencies: [
                "RepoPromptServerOperations",
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAuthorityAPI", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SQLiteNIO", package: "sqlite-nio")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptMCPAdapter",
            dependencies: [
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAuthorityAPI", package: "RepoPromptPortableRuntime"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptServiceHTTP",
            dependencies: [
                "RepoPromptServiceProtocol",
                "RepoPromptServerOperations",
                .product(name: "RepoPromptAuthorityAPI", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates")
            ],
            resources: [.process("Resources")],
            swiftSettings: swift6LanguageMode
        ),
        .target(
            name: "RepoPromptServerHost",
            dependencies: [
                "RepoPromptServiceProtocol",
                "RepoPromptServerOperations",
                "RepoPromptServicePersistence",
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAuthorityAPI", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptHeadlessRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptWorkspaceRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptLinuxSupport", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptShared", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .executableTarget(
            name: "RepoPromptServerExecutable",
            dependencies: [
                "RepoPromptServerHost",
                "RepoPromptServiceHTTP",
                "RepoPromptMCPAdapter",
                "RepoPromptServiceProtocol",
                "RepoPromptServicePersistence",
                "RepoPromptServerOperations",
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptHeadlessRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptWorkspaceRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: swift6LanguageMode
        ),
        .executableTarget(
            name: "RepoPromptMCPHeadlessExecutable",
            dependencies: [
                "RepoPromptServerHost",
                "RepoPromptMCPAdapter"
            ],
            swiftSettings: swift6LanguageMode
        ),
        .testTarget(
            name: "RepoPromptServerTests",
            dependencies: [
                "RepoPromptServiceProtocol",
                "RepoPromptServerOperations",
                "RepoPromptServicePersistence",
                "RepoPromptServiceHTTP",
                "RepoPromptMCPAdapter",
                "RepoPromptServerHost",
                "RepoPromptServerExecutable",
                "RepoPromptMCPHeadlessExecutable",
                .product(name: "RepoPromptRuntimeModel", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptAgentRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptDomainRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptHeadlessRuntime", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptShared", package: "RepoPromptPortableRuntime"),
                .product(name: "RepoPromptWorkspaceRuntimeCore", package: "RepoPromptPortableRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "X509", package: "swift-certificates")
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swift6LanguageMode
        )
    ],
    swiftLanguageModes: [.v5]
)
