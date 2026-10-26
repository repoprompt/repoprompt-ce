import Foundation

package enum CodeMapSyntaxArtifactBuilder {
    package static func build(
        source: CodeMapCoreSourceSnapshot,
        language: LanguageType,
        syntaxEngine: any CodeMapSyntaxQuerying = CodeMapSyntaxEngine.shared,
        performanceOptions: CodeMapPerfOptions = .disabled,
        performanceCollector: CodeMapPerformanceCollector? = nil
    ) throws -> CodeMapSyntaxArtifactOutcome {
        let builderStart = performanceCollector.map { _ in ProcessInfo.processInfo.systemUptime }
        defer {
            if let builderStart {
                performanceCollector?.builderTotalDuration += ProcessInfo.processInfo.systemUptime - builderStart
            }
        }

        guard case let .decoded(decodedSource) = source.decodeResult else {
            guard case let .failed(failure) = source.decodeResult else {
                preconditionFailure("CodeMapSourceDecodeResult gained an unhandled case.")
            }
            return .decodeFailed(failure)
        }

        let content = decodedSource.text
        let syntaxOutcome: CodeMapSyntaxQueryOutcome
        if let performanceEngine = syntaxEngine as? any CodeMapSyntaxPerformanceQuerying {
            syntaxOutcome = try performanceEngine.codeMap(
                content: content,
                language: language,
                performanceCollector: performanceCollector
            )
        } else {
            syntaxOutcome = try syntaxEngine.codeMap(content: content, language: language)
        }

        switch syntaxOutcome {
        case let .captures(captures):
            let generatorStart = performanceCollector.map { _ in ProcessInfo.processInfo.systemUptime }
            let artifact = CodeMapGenerator.generateSyntaxArtifact(
                from: captures,
                content: content,
                language: language,
                perfOptions: performanceOptions,
                perfStats: performanceCollector
            )
            if let generatorStart {
                performanceCollector?.builderGeneratorDuration += ProcessInfo.processInfo.systemUptime - generatorStart
            }
            guard let artifact else {
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
