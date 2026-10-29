package struct ACPToolNameResolution {
    package let isRepoPromptServerIdentifier: @Sendable (String?) -> Bool
    package let canonicalRepoPromptToolName: @Sendable (String?) -> String?
    package let isRepoPromptToolNameWithServerPrefix: @Sendable (String) -> Bool

    package init(
        isRepoPromptServerIdentifier: @escaping @Sendable (String?) -> Bool,
        canonicalRepoPromptToolName: @escaping @Sendable (String?) -> String?,
        isRepoPromptToolNameWithServerPrefix: @escaping @Sendable (String) -> Bool
    ) {
        self.isRepoPromptServerIdentifier = isRepoPromptServerIdentifier
        self.canonicalRepoPromptToolName = canonicalRepoPromptToolName
        self.isRepoPromptToolNameWithServerPrefix = isRepoPromptToolNameWithServerPrefix
    }
}
