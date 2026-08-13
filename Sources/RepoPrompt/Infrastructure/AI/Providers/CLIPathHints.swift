import Foundation

enum CLIPathHints {
    // Compatibility facade: callers that expect provider-owned hints keep receiving
    // provider-specific paths, while CLILaunchProfiles owns effective search paths.
    static let claudeCode: [String] = CLILaunchProfiles.claudeCodeProviderSpecificPaths
    static let codex: [String] = CLILaunchProfiles.codex.supplementalSearchPaths
    static let openCode: [String] = CLILaunchProfiles.openCodeProviderSpecificPaths
    static let cursor: [String] = CLILaunchProfiles.cursorProviderSpecificPaths
    static let grokBuild: [String] = CLILaunchProfiles.grokBuildProviderSpecificPaths

    static func nativeDefaultsSupplemented(with providerSpecificPaths: [String]) -> [String] {
        CLILaunchProfiles.nativeDefaultsSupplemented(with: providerSpecificPaths)
    }
}
