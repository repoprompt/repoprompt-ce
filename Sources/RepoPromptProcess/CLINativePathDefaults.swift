import Foundation

enum CLINativePathDefaults {
    static let homebrewBins: [String] = [
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin"
    ]

    static let systemBins: [String] = orderedUnique(
        homebrewBins + [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    )

    static let nodePackageManagerBins: [String] = [
        "~/.volta/bin",
        "~/.local/share/pnpm",
        "~/.yarn/bin",
        "~/.config/yarn/global/node_modules/.bin",
        "~/.npm-global/bin"
    ]

    static let versionManagerShimBins: [String] = [
        "~/.config/mise/shims",
        "~/.asdf/shims",
        "~/.nodenv/shims",
        "~/.pyenv/shims",
        "~/.rbenv/shims"
    ]

    static let userToolBins: [String] = [
        "~/.local/bin",
        "~/bin",
        "~/go/bin",
        "~/.cargo/bin",
        "~/.bun/bin"
    ]

    static let defaultAdditionalPaths: [String] = orderedUnique(
        systemBins +
            nodePackageManagerBins +
            versionManagerShimBins +
            userToolBins
    )

    static let loginShellFallbackCandidates: [String] = orderedUnique(
        homebrewBins +
            nodePackageManagerBins +
            versionManagerShimBins +
            userToolBins
    )

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }
}
