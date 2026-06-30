enum CodeMapSyntaxArtifactBuilder {
    static func build(
        source: CodeMapSourceSnapshot,
        language: LanguageType,
        syntaxManager: any CodeMapSyntaxQuerying = SyntaxManager.shared
    ) throws -> CodeMapSyntaxArtifactOutcome {
        guard case let .decoded(decodedSource) = source.decodeResult else {
            guard case let .failed(failure) = source.decodeResult else {
                preconditionFailure("CodeMapSourceDecodeResult gained an unhandled case.")
            }
            return .decodeFailed(failure)
        }

        let content = decodedSource.text
        switch try syntaxManager.codeMap(content: content, language: language) {
        case let .captures(captures):
            guard let artifact = CodeMapGenerator.generateSyntaxArtifact(
                from: captures,
                content: content,
                language: language
            ) else {
                return .readyNoSymbols
            }
            return .ready(artifact)
        case let .oversize(reason):
            return .oversize(reason)
        case let .parseFailed(failure):
            return .parseFailed(failure)
        }
    }
}
