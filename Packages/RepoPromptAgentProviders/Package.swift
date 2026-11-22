// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoPromptAgentProviders",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "RepoPromptClaudeCompatibleProvider",
            targets: ["RepoPromptClaudeCompatibleProvider"]
        )
    ],
    targets: [
        .target(
            name: "RepoPromptClaudeCompatibleProvider",
            path: "Sources/RepoPromptClaudeCompatibleProvider",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptClaudeCompatibleProviderTests",
            dependencies: ["RepoPromptClaudeCompatibleProvider"],
            path: "Tests/RepoPromptClaudeCompatibleProviderTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v5]
)
