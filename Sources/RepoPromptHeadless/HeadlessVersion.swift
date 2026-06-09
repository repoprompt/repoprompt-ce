enum HeadlessVersion {
    static let executableName = "repoprompt-headless"
    static let displayName = "RepoPrompt Headless"
    static let marketingVersion = "1.0.6"
    static let buildNumber = "7"
    static let mcpProtocolVersion = "2024-11-05"
    static let secureStorageNamespace = "com.pvncher.repoprompt.ce.headless.keychain"

    static var versionString: String {
        "\(marketingVersion) (build \(buildNumber))"
    }
}
