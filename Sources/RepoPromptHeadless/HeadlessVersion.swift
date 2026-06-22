/// Generated from version.env for the current source release. The standalone
/// packaging lane verifies these values before building and records them in the
/// artifact manifest.
enum HeadlessVersion {
    static let executableName = "repoprompt-headless"
    static let displayName = "RepoPrompt Headless"
    static let marketingVersion = "1.0.21"
    static let buildNumber = "22"
    static let mcpProtocolVersion = "2024-11-05"
    static let secureStorageNamespace = "com.pvncher.repoprompt.ce.headless.keychain"

    static var versionString: String {
        "\(marketingVersion) (build \(buildNumber))"
    }
}
