import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class PromptTokenEstimateParityTests: XCTestCase {
    private let rootID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let modificationDate = Date(timeIntervalSince1970: 1000)

    func testClipboardExactProjectionCountsTitleDatetimeAndIntentionalDuplicationFromRenderedBytes() async {
        let renderingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let dateString = formatter.string(from: renderingDate)
        let files: [ResolvedPromptFileEntry] = []

        let text = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [MetaInstruction(title: "Rules", content: "Be exact")],
            userInstructions: "Ship it",
            files: files,
            fileTreeContent: nil,
            includeSavedPrompts: true,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .full,
            includeDatetimeInUserInstructions: true,
            renderingDate: renderingDate,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [.userInstructions],
            duplicateUserInstructionsAtTop: true,
            tabTitle: "Plan & <Review>"
        )
        let payload = PromptPackagingService.exactRenderedPayload(text, source: .immutableSnapshot)

        XCTAssertTrue(text.hasPrefix("<title>\nPlan &amp; &lt;Review&gt;\n</title>\n"), text)
        XCTAssertTrue(text.contains("<user_instructions date=\"\(dateString)\">"), text)
        XCTAssertEqual(occurrences(of: "Ship it", in: text), 1)
        XCTAssertEqual(occurrences(of: "Be exact", in: text), 1)
        assertExactProjection(payload.projection, text: text, source: .immutableSnapshot)
    }

    func testGenericTitleIsOmittedFromExactClipboardPayload() async {
        let files: [ResolvedPromptFileEntry] = []
        let text = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Prompt",
            files: files,
            fileTreeContent: nil,
            includeSavedPrompts: false,
            includeFiles: false,
            includeUserPrompt: true,
            filePathDisplay: .full,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false,
            tabTitle: "T42"
        )
        let payload = PromptPackagingService.exactRenderedPayload(text, source: .virtualRecomputed)

        XCTAssertFalse(text.contains("<title>"), text)
        assertExactProjection(payload.projection, text: text, source: .virtualRecomputed)
    }

    func testSelectedGitArtifactUsesSingleClassifierSuppressesFallbackAndCountsRenderedBlocksOnce() async {
        let full = makeEntry(relativePath: "Sources/Full.swift", content: "struct Full {}\n")
        let diff = makeEntry(
            relativePath: "_git_data/repos/demo/2026-06-05/diff/all.patch",
            content: "PATCH-CONTENT"
        )
        let entries = [full, diff]

        XCTAssertTrue(PromptGitDiffArtifactClassifier.isDiffArtifactPath(diff.file.fullPath))
        XCTAssertTrue(PromptGitDiffArtifactClassifier.isDiffArtifactPath("/workspace/_git_data/repos/demo/diffs/ALL.DIFF"))
        XCTAssertFalse(PromptGitDiffArtifactClassifier.isDiffArtifactPath("/workspace/_git_data/repos/demo/index/map.txt"))
        XCTAssertFalse(PromptGitDiffArtifactClassifier.isDiffArtifactPath("/workspace/Sources/change.patch"))

        let text = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Review",
            files: entries,
            fileTreeContent: nil,
            gitDiff: "GENERATED-FALLBACK",
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .full,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )
        let payload = PromptPackagingService.exactRenderedPayload(text, source: .immutableSnapshot)

        XCTAssertEqual(occurrences(of: "PATCH-CONTENT", in: text), 1)
        XCTAssertEqual(occurrences(of: "GENERATED-FALLBACK", in: text), 0)
        XCTAssertEqual(occurrences(of: "struct Full", in: text), 1)
        XCTAssertEqual(occurrences(of: "_git_data/", in: text), 0)
        assertExactProjection(payload.projection, text: text, source: .immutableSnapshot)
    }

    func testCanonicalChatPayloadCountsEachMessageContentAndWrapperExactlyAsPackaged() {
        let message = PromptPackagingService.buildAIMessage(
            systemPrompt: "SYSTEM",
            metaInstructions: [MetaInstruction(title: "Meta", content: "META-CONTENT")],
            fileTree: "TREE-CONTENT",
            fileContents: ["FILE-CONTENT"],
            gitDiff: "DIFF-CONTENT",
            conversation: [
                ConversationEntry(role: .user, content: "EARLY-PROMPT-CONTENT"),
                ConversationEntry(role: .assistant, content: "HISTORY-CONTENT"),
                ConversationEntry(role: .user, content: "USER-CONTENT")
            ],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: true,
            tailAssemblyStrategy: .coreStandardChat
        )
        let payload = PromptPackagingService.exactChatPayload(for: message, source: .activeLive)

        XCTAssertEqual(payload.text, flattenedOpenAIChatPayload(for: message))
        XCTAssertEqual(occurrences(of: "SYSTEM", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "EARLY-PROMPT-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "HISTORY-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "TREE-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "FILE-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "DIFF-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "META-CONTENT", in: payload.text), 1)
        XCTAssertEqual(occurrences(of: "USER-CONTENT", in: payload.text), 2)
        assertExactProjection(payload.projection, text: payload.text, source: .activeLive)
    }

    func testCanonicalChatPayloadMatchesTransportWhenConversationHasNoUser() {
        let message = PromptPackagingService.buildAIMessage(
            systemPrompt: "SYSTEM",
            metaInstructions: [MetaInstruction(title: "Meta", content: "UNEMITTED-META")],
            fileTree: "UNEMITTED-TREE",
            fileContents: ["UNEMITTED-FILE"],
            gitDiff: "UNEMITTED-DIFF",
            conversation: [ConversationEntry(role: .assistant, content: "ASSISTANT-ONLY")],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: true,
            tailAssemblyStrategy: .coreStandardChat
        )
        let payload = PromptPackagingService.exactChatPayload(for: message, source: .immutableSnapshot)

        XCTAssertEqual(payload.text, flattenedOpenAIChatPayload(for: message))
        XCTAssertEqual(payload.text, "SYSTEMASSISTANT-ONLY")
        XCTAssertFalse(payload.text.contains("UNEMITTED"), payload.text)
        assertExactProjection(payload.projection, text: payload.text, source: .immutableSnapshot)
    }

    @MainActor
    func testSelectedGitArtifactCountsAsFileAndSuppressesGeneratedGitComponent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("PromptTokenArtifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let artifactURL = rootURL
            .appendingPathComponent("_git_data/repos/demo/2026-06-05/diff", isDirectory: true)
            .appendingPathComponent("all.patch")
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let artifactContent = "PATCH-CONTENT\n"
        try artifactContent.write(to: artifactURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootURL.path)
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let gitViewModel = GitViewModel(fileManager: fileManager)
        let selection = StoredSelection(selectedPaths: [artifactURL.path])
        let viewModel = TokenCountingViewModel()
        viewModel.configure(
            fileManager: fileManager,
            gitViewModel: gitViewModel,
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: {
                TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: .none,
                    codeMapUsage: .none,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: true,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: false
                )
            },
            getCopyContext: {
                TokenCountingViewModel.CopyContextSnapshot(
                    includeFiles: true,
                    includeUserPrompt: false,
                    includeMetaPrompts: false,
                    includeFileTree: false,
                    fileTreeMode: .none,
                    codeMapUsage: .none,
                    gitInclusion: .complete,
                    duplicateUserInstructionsAtTop: false
                )
            },
            getStoredSelection: { selection }
        )
        viewModel.suspendAutomaticRecounts()

        await viewModel.forceImmediateRecount()
        let breakdown = viewModel.latestTokenBreakdown()

        XCTAssertEqual(breakdown.files, TokenCalculationService.estimateTokens(for: artifactContent))
        XCTAssertEqual(breakdown.git, 0)
        XCTAssertEqual(breakdown.total, breakdown.files + breakdown.other)
        await viewModel.stopTokenCountUpdateTimer()
    }

    private func makeEntry(relativePath: String, content: String?) -> ResolvedPromptFileEntry {
        let rootPath = "/workspace/Alpha"
        let file = WorkspaceFileRecord(
            id: UUID(),
            rootID: rootID,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            fullPath: "\(rootPath)/\(relativePath)",
            parentFolderID: nil,
            modificationDate: modificationDate
        )
        return ResolvedPromptFileEntry(
            file: file,
            loadedContent: content,
            rootFolderPath: rootPath
        )
    }

    private func flattenedOpenAIChatPayload(for message: AIMessage) -> String {
        message.openAIChatMessages(embedSystemPrompt: false).map { transportMessage in
            switch transportMessage.content {
            case let .text(text):
                text
            case let .contentArray(items):
                items.compactMap { item in
                    if case let .text(text) = item { return text }
                    return nil
                }.joined()
            }
        }.joined()
    }

    private func assertExactProjection(
        _ projection: TokenProjection,
        text: String,
        source: TokenProjection.Source,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(projection.provenance.view, .userConfigured, file: file, line: line)
        XCTAssertEqual(projection.provenance.scope, .export, file: file, line: line)
        XCTAssertEqual(projection.provenance.source, source, file: file, line: line)
        XCTAssertEqual(projection.provenance.basis, .exactRenderedPayload, file: file, line: line)
        XCTAssertEqual(projection.components, .init(), file: file, line: line)
        XCTAssertEqual(
            projection.total,
            TokenCalculationService.estimateTokens(for: text),
            file: file,
            line: line
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
