/// Captures the slice-rebase registration generations that must remain quiescent
/// while an authoritative workspace selection is verified.
struct WorkspaceSliceRebaseFence {
    let registrationGenerationsByFullPath: [String: UInt64]
    let unresolvedCandidatePaths: Set<String>
}
