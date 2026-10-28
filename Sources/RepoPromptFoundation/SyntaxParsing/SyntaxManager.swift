//
//  SyntaxManager.swift
//  RepoPrompt
//

import RepoPromptCodeMapCore

/// App-facing façade for the shared CodeMap syntax engine.
///
/// Grammar ownership, query compilation, parsing, and extraction live in
/// `RepoPromptCodeMapCore`. This façade preserves the app's stable CodeMap
/// call surface without retaining the removed syntax-highlighting pipeline.
package final class SyntaxManager: @unchecked Sendable {
    package init() {}
    package static let shared = SyntaxManager()

    package static let parseLineLimit = CodeMapSyntaxEngine.parseLineLimit
    package static let parseUTF16Limit = CodeMapSyntaxEngine.parseUTF16Limit
    package static let parseUTF8Limit = CodeMapSyntaxEngine.parseUTF8Limit

    package var extensionToLanguage: [String: LanguageType] {
        CodeMapSyntaxEngine.extensionToLanguage
    }

    package func language(forFileExtension fileExtension: String) -> LanguageType? {
        CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension)
    }

    package func codeMapPipelineDescriptor(for languageType: LanguageType) throws -> CodeMapLanguagePipelineDescriptor {
        try CodeMapSyntaxEngine.shared.codeMapPipelineDescriptor(for: languageType)
    }

    package func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        try CodeMapSyntaxEngine.shared.pipelineIdentity(
            for: languageType,
            decoderPolicy: decoderPolicy
        )
    }

    package func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try CodeMapSyntaxEngine.shared.codeMap(content: content, language: language)
    }

    package static func isSupportedFileExtension(_ fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.isSupportedFileExtension(fileExtension)
    }

    package static func supportsCodeMap(fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.supportsCodeMap(fileExtension: fileExtension)
    }

    package func supportsCodeMap(fileExtension: String) -> Bool {
        Self.supportsCodeMap(fileExtension: fileExtension)
    }

    package static func isLightweight(language: LanguageType) -> Bool {
        CodeMapSyntaxEngine.isLightweight(language: language)
    }
}
