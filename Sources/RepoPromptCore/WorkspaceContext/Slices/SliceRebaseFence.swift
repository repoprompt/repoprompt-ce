/// Captures the slice-rebase registration generations that must remain quiescent
/// while an authoritative workspace selection is verified.
package struct WorkspaceSliceRebaseFence {
    package let registrationGenerationsByFullPath: [String: UInt64]
    package let unresolvedCandidatePaths: Set<String>

    package init(
        registrationGenerationsByFullPath: [String: UInt64],
        unresolvedCandidatePaths: Set<String>
    ) {
        self.registrationGenerationsByFullPath = registrationGenerationsByFullPath
        self.unresolvedCandidatePaths = unresolvedCandidatePaths
    }
}
