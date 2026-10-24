import RepoPromptCodeMapCore

extension CodeMapArtifactKey {
    init(source: CodeMapSourceSnapshot, pipelineIdentity: CodeMapPipelineIdentity) throws {
        try self.init(source: source.coreSnapshot, pipelineIdentity: pipelineIdentity)
    }
}
