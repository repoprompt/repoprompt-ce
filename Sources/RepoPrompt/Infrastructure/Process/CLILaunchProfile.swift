import Foundation

struct CLILaunchProfile: Equatable {
    let commandName: String
    let preferredBasenames: [String]
    let supplementalSearchPaths: [String]
}

enum CLILaunchProfiles {
    static let claudeCodeProviderSpecificPaths: [String] = [
        "~/.claude/local"
    ]

    static let openCodeProviderSpecificPaths: [String] = [
        "~/.opencode/bin"
    ]
    static let cursorProviderSpecificPaths: [String] = []

    /// Preserve the committed Codex hint order exactly: shell/package-manager
    /// fallbacks first, then Codex.app resources. System bins are intentionally not
    /// added as supplemental hints because the resolver already searches the built
    /// child PATH, which comes from the user's shell/inherited environment.
    static let codexSupplementalSearchPaths: [String] = orderedUnique(
        CLINativePathDefaults.homebrewBins +
            CLINativePathDefaults.nodePackageManagerBins +
            [
                "~/.bun/bin"
            ] +
            CLINativePathDefaults.versionManagerShimBins +
            [
                "~/.cargo/bin",
                "~/.local/bin",
                "~/bin",
                "~/go/bin",
                "/Applications/Codex.app/Contents/Resources"
            ]
    )

    static let claudeCode = CLILaunchProfile(
        commandName: "claude",
        preferredBasenames: ["claude"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: claudeCodeProviderSpecificPaths)
    )

    static let codex = CLILaunchProfile(
        commandName: "codex",
        preferredBasenames: ["codex"],
        supplementalSearchPaths: codexSupplementalSearchPaths
    )

    static let openCode = CLILaunchProfile(
        commandName: "opencode",
        preferredBasenames: ["opencode"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(openCodeProviderSpecificPaths)
    )

    static let cursor = CLILaunchProfile(
        commandName: "cursor-agent",
        preferredBasenames: ["cursor-agent"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: cursorProviderSpecificPaths)
    )

    static func nativeDefaultsSupplemented(with providerSpecificPaths: [String]) -> [String] {
        orderedUnique(CLINativePathDefaults.defaultAdditionalPaths + providerSpecificPaths)
    }

    static func providerSpecificPathsSupplementedWithNativeDefaults(_ providerSpecificPaths: [String]) -> [String] {
        orderedUnique(providerSpecificPaths + CLINativePathDefaults.defaultAdditionalPaths)
    }

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }
}
