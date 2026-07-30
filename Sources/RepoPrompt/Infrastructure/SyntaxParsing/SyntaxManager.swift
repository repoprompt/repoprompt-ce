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
final class SyntaxManager: @unchecked Sendable {
    static let shared = SyntaxManager()

    static let parseLineLimit = CodeMapSyntaxEngine.parseLineLimit
    static let parseUTF16Limit = CodeMapSyntaxEngine.parseUTF16Limit
    static let parseUTF8Limit = CodeMapSyntaxEngine.parseUTF8Limit

    var extensionToLanguage: [String: LanguageType] {
        CodeMapSyntaxEngine.extensionToLanguage
    }

    func language(forFileExtension fileExtension: String) -> LanguageType? {
        CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension)
    }

    func codeMapPipelineDescriptor(for languageType: LanguageType) throws -> CodeMapLanguagePipelineDescriptor {
        try CodeMapSyntaxEngine.shared.codeMapPipelineDescriptor(for: languageType)
    }

    func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        try CodeMapSyntaxEngine.shared.pipelineIdentity(
            for: languageType,
            decoderPolicy: decoderPolicy
        )
    }

    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try CodeMapSyntaxEngine.shared.codeMap(content: content, language: language)
    }

    static func isSupportedFileExtension(_ fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.isSupportedFileExtension(fileExtension)
    }

    static func supportsCodeMap(fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.supportsCodeMap(fileExtension: fileExtension)
    }

    func supportsCodeMap(fileExtension: String) -> Bool {
        Self.supportsCodeMap(fileExtension: fileExtension)
    }

    static func isLightweight(language: LanguageType) -> Bool {
        CodeMapSyntaxEngine.isLightweight(language: language)
    }
}
