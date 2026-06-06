import Foundation
import RepoPromptCore

struct MetaInstruction {
    let title: String
    let content: String
}

enum PromptGitDiffArtifactClassifier {
    static let rootFolderName = "_git_data"

    static func isDiffArtifactPath(_ fullPath: String) -> Bool {
        guard fullPath.contains("/\(rootFolderName)/") else { return false }
        let lower = fullPath.lowercased()
        guard lower.hasSuffix(".diff") || lower.hasSuffix(".patch") else { return false }
        return lower.contains("/diff/") || lower.contains("/diffs/")
    }
}

enum PromptPackagingService {
    struct ExactRenderedPayload {
        let text: String
        let projection: TokenProjection
    }

    static func exactRenderedPayload(
        _ text: String,
        source: TokenProjection.Source
    ) -> ExactRenderedPayload {
        ExactRenderedPayload(
            text: text,
            projection: TokenProjectionService.exactRenderedPayload(
                text,
                view: .userConfigured,
                source: source
            )
        )
    }

    static func exactChatPayload(
        for message: AIMessage,
        source: TokenProjection.Source
    ) -> ExactRenderedPayload {
        exactRenderedPayload(renderedChatPayload(for: message), source: source)
    }

    static func renderedChatPayload(for message: AIMessage) -> String {
        var contents: [String] = []
        if !message.systemPrompt.isEmpty {
            contents.append(message.systemPrompt)
        }

        let tail = message.buildTail(embedSystemPrompt: false)
        let lastUserIndex = message.conversationMessages.lastIndex { $0.role == .user }
        for (index, entry) in message.conversationMessages.enumerated() {
            let text = entry.role == .user && index == lastUserIndex && !tail.isEmpty
                ? tail + "\n" + entry.content
                : entry.content
            contents.append(text)
        }
        return contents.joined()
    }

    /// Returns the opening ``` fence, suffixed with the file extension (\"swift\", \"js\", …).
    @inline(__always)
    static func codeFenceStart(for fileName: String) -> String {
        PromptRenderingService.codeFenceStart(for: fileName)
    }

    // NEW: Helpers for title snippet
    private static func isGenericTabTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^T\d+$"#, options: .regularExpression) != nil
    }

    private static func escapeXML(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }

    private static func titleSnippet(for tabTitle: String?) -> String? {
        guard let raw = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return nil
        }
        guard isGenericTabTitle(raw) == false else { return nil }
        let escaped = escapeXML(raw)
        return """
        <title>
        \(escaped)
        </title>

        """
    }

    static func partitionPromptEntriesForGitDiff(
        _ entries: [PromptFileEntry]
    ) -> (diffEntries: [PromptFileEntry], codeEntries: [PromptFileEntry]) {
        guard !entries.isEmpty else { return ([], []) }
        var diffEntries: [PromptFileEntry] = []
        var codeEntries: [PromptFileEntry] = []
        diffEntries.reserveCapacity(entries.count)
        codeEntries.reserveCapacity(entries.count)

        for entry in entries {
            if PromptGitDiffArtifactClassifier.isDiffArtifactPath(entry.file.fullPath) {
                diffEntries.append(entry)
            } else {
                codeEntries.append(entry)
            }
        }
        return (diffEntries, codeEntries)
    }

    static func selectedGitDiffText(
        fromDiffEntries diffEntries: [PromptFileEntry]
    ) async -> String? {
        await PromptRenderingService.renderSelectedDiffText(renderingDiffValues(diffEntries))
    }

    static func selectedGitDiffText(
        from entries: [PromptFileEntry]
    ) async -> String? {
        let (diffEntries, _) = partitionPromptEntriesForGitDiff(entries)
        return await selectedGitDiffText(fromDiffEntries: diffEntries)
    }

    static func resolveGitDiff(
        fromDiffEntries diffEntries: [PromptFileEntry],
        fallback: @Sendable () async -> String?
    ) async -> String? {
        if let selected = await selectedGitDiffText(fromDiffEntries: diffEntries) {
            return selected
        }
        return await fallback()
    }

    static func resolveGitDiff(
        from entries: [PromptFileEntry],
        fallback: @Sendable () async -> String?
    ) async -> String? {
        if let selected = await selectedGitDiffText(from: entries) {
            return selected
        }
        return await fallback()
    }

    static func generateRawFileTexts(
        _ entries: [PromptFileEntry]
    ) async -> [String] {
        await PromptRenderingService.renderDiffParts(renderingDiffValues(entries))
    }

    /// Build an AIMessage that includes:
    /// - system prompt
    /// - meta prompts
    /// - file tree & blocks
    /// - an entire conversation array in chronological order
    static func buildAIMessage(
        systemPrompt: String,
        metaInstructions: [MetaInstruction],
        fileTree: String,
        fileContents: [String],
        gitDiff: String? = nil,
        conversation: [ConversationEntry],
        temperature: Double?,
        promptSectionsOrder: [PromptSection],
        disabledPromptSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool = false
    ) -> AIMessage {
        // 1️⃣  Turn meta-instructions into prompt strings
        let metaPrompts: [String] = metaInstructions.map { meta in
            """
            <meta prompt "\(meta.title)">
            \(meta.content)
            </meta prompt>
            """
        }

        // 2️⃣  Copy conversation and rebuild the final user entry once
        var updatedConversation = conversation
        if let lastUserIndex = updatedConversation.lastIndex(where: { $0.role == .user }) {
            let lastUserEntry = updatedConversation[lastUserIndex]
            var newContent = lastUserEntry.content

            // Wrap in <user_instructions> … </user_instructions> if not already wrapped
            if !newContent.contains("<user_instructions>") {
                newContent = """
                <user_instructions>
                \(newContent)
                </user_instructions>
                """
            }

            // Replace the immutable entry with a new one
            updatedConversation[lastUserIndex] =
                ConversationEntry(role: lastUserEntry.role, content: newContent)
        }

        // 3️⃣  Package everything into AIMessage
        return AIMessage(
            systemPrompt: systemPrompt,
            metaPrompts: metaPrompts,
            fileTree: fileTree,
            fileBlocks: fileContents,
            gitDiff: gitDiff,
            conversationMessages: updatedConversation,
            temperature: temperature,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }

    /// Produce file contents as an array of strings, each with the file path + raw content
    static func partitionPromptEntriesForGitDiff(
        _ entries: [ResolvedPromptFileEntry]
    ) -> (diffEntries: [ResolvedPromptFileEntry], codeEntries: [ResolvedPromptFileEntry]) {
        guard !entries.isEmpty else { return ([], []) }
        var diffEntries: [ResolvedPromptFileEntry] = []
        var codeEntries: [ResolvedPromptFileEntry] = []
        diffEntries.reserveCapacity(entries.count)
        codeEntries.reserveCapacity(entries.count)

        for entry in entries {
            if PromptGitDiffArtifactClassifier.isDiffArtifactPath(entry.file.fullPath) {
                diffEntries.append(entry)
            } else {
                codeEntries.append(entry)
            }
        }
        return (diffEntries, codeEntries)
    }

    static func selectedGitDiffText(
        fromDiffEntries diffEntries: [ResolvedPromptFileEntry]
    ) -> String? {
        PromptRenderingService.renderSelectedDiffText(renderingDiffValues(diffEntries))
    }

    static func selectedGitDiffText(
        from entries: [ResolvedPromptFileEntry]
    ) -> String? {
        let (diffEntries, _) = partitionPromptEntriesForGitDiff(entries)
        return selectedGitDiffText(fromDiffEntries: diffEntries)
    }

    static func resolveGitDiff(
        fromDiffEntries diffEntries: [ResolvedPromptFileEntry],
        fallback: @Sendable () async -> String?
    ) async -> String? {
        if let selected = selectedGitDiffText(fromDiffEntries: diffEntries) {
            return selected
        }
        return await fallback()
    }

    static func resolveGitDiff(
        from entries: [ResolvedPromptFileEntry],
        fallback: @Sendable () async -> String?
    ) async -> String? {
        if let selected = selectedGitDiffText(from: entries) {
            return selected
        }
        return await fallback()
    }

    static func generateRawFileTexts(
        _ entries: [ResolvedPromptFileEntry]
    ) -> [String] {
        PromptRenderingService.renderDiffParts(renderingDiffValues(entries))
    }

    static func generateFileContents(
        _ files: [ResolvedPromptFileEntry],
        filePathDisplay: FilePathDisplay = .full,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot] = [:],
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) -> [String] {
        let (_, contentBlocks) = generatePartitionedFileBlocks(files, filePathDisplay: filePathDisplay, codemapSnapshots: codemapSnapshots, displayPathResolver: displayPathResolver)
        return contentBlocks
    }

    static func generatePartitionedFileBlocks(
        _ files: [ResolvedPromptFileEntry],
        filePathDisplay: FilePathDisplay,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot] = [:],
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) -> (codemapBlocks: [String], contentBlocks: [String]) {
        let (_, codeEntries) = partitionPromptEntriesForGitDiff(files)
        let values = renderingFileValues(
            codeEntries,
            filePathDisplay: filePathDisplay,
            codemapSnapshots: codemapSnapshots,
            displayPathResolver: displayPathResolver
        )
        let partitioned = PromptRenderingService.renderPartitionedFileBlocks(values)
        return (partitioned.codemapBlocks, partitioned.contentBlocks)
    }

    static func generateFileBlocksDetailed(
        files: [ResolvedPromptFileEntry],
        filePathDisplay: FilePathDisplay,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot] = [:],
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) -> [ResolvedPromptFileBlockRecord] {
        let values = renderingFileValues(
            files,
            filePathDisplay: filePathDisplay,
            codemapSnapshots: codemapSnapshots,
            displayPathResolver: displayPathResolver
        )
        return PromptRenderingService.renderFileBlocks(values).map { block in
            let entry = files[block.inputIndex]
            return ResolvedPromptFileBlockRecord(
                entry: entry,
                file: entry.file,
                text: block.text,
                isCodemap: block.kind == .codemap
            )
        }
    }

    /// Produce file contents as an array of strings, each with the file path + raw content
    static func generateFileContents(
        _ files: [PromptFileEntry],
        filePathDisplay: FilePathDisplay = .full
    ) async -> [String] {
        let (_, contentBlocks) = await generatePartitionedFileBlocks(files, filePathDisplay: filePathDisplay)
        return contentBlocks
    }

    /// Partitions file blocks into codemap blocks and content blocks
    static func generatePartitionedFileBlocks(
        _ files: [PromptFileEntry],
        filePathDisplay: FilePathDisplay
    ) async -> (codemapBlocks: [String], contentBlocks: [String]) {
        let (_, codeEntries) = partitionPromptEntriesForGitDiff(files)
        let values = await renderingFileValues(codeEntries, filePathDisplay: filePathDisplay)
        let partitioned = PromptRenderingService.renderPartitionedFileBlocks(values)
        return (partitioned.codemapBlocks, partitioned.contentBlocks)
    }

    static func generateFileBlocksDetailed(
        files: [PromptFileEntry],
        filePathDisplay: FilePathDisplay
    ) async -> [(file: FileViewModel, text: String, isCodemap: Bool)] {
        let values = await renderingFileValues(files, filePathDisplay: filePathDisplay)
        return PromptRenderingService.renderFileBlocks(values).map { block in
            (files[block.inputIndex].file, block.text, block.kind == .codemap)
        }
    }

    static func generatePrompt(
        systemPrompt: String,
        metaInstructions: [MetaInstruction],
        userInstructions: String,
        files: [PromptFileEntry],
        filePathDisplay: FilePathDisplay,
        fileTreeContent: String?, // NEW simplified parameter for the file tree
        gitDiff: String? = nil,
        includeDatetimeInUserInstructions: Bool = false,
        renderingDate: Date? = nil,
        // Add parameters needed by PromptAssemblyBuilder
        promptSectionsOrder: [PromptSection],
        disabledPromptSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool
    ) async -> AIMessage {
        // --- Generate Snippets ---
        var snippets: [PromptSection: String] = [:]

        let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
        let (codemapBlocks, contentBlocks) = await generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay)

        // Meta Prompts Snippet
        if let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
            snippets[.metaPrompts] = metaSnippet
        }

        let effectiveGitDiff = await resolveGitDiff(
            fromDiffEntries: diffEntries
        ) {
            gitDiff
        }
        let factualSnippets = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: fileTreeContent,
            codemapBlocks: codemapBlocks,
            contentBlocks: contentBlocks,
            gitDiff: effectiveGitDiff
        )
        applyFactualSnippets(factualSnippets, to: &snippets)

        // User Instructions Snippet
        if !userInstructions.isEmpty {
            snippets[.userInstructions] = userInstructionsSnippet(
                userInstructions,
                includeDatetime: includeDatetimeInUserInstructions,
                renderingDate: renderingDate
            )
        }

        // --- Build Final User Message ---
        let userMessage = PromptAssemblyBuilder.build(
            order: promptSectionsOrder,
            disabled: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets
        )

        // --- Return AIMessage ---
        return AIMessage(
            systemPrompt: systemPrompt,
            userMessage: userMessage
        )
    }

    static func generateClipboardContent(
        metaInstructions: [MetaInstruction],
        userInstructions: String,
        files: [PromptFileEntry],
        fileTreeContent: String?, // NEW simplified parameter for the file tree
        gitDiff: String? = nil,
        includeSavedPrompts: Bool,
        includeFiles: Bool,
        includeUserPrompt: Bool,
        filePathDisplay: FilePathDisplay,
        includeDatetimeInUserInstructions: Bool = false,
        renderingDate: Date? = nil,
        promptSectionsOrder: [PromptSection],
        disabledPromptSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        tabTitle: String? = nil,
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) async -> String {
        // --- Generate Snippets ---
        var snippets: [PromptSection: String] = [:]

        let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
        let (codemapBlocks, contentBlocks) = await generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay)

        // Meta Prompts Snippet
        if includeSavedPrompts, let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
            snippets[.metaPrompts] = metaSnippet
        }

        let effectiveGitDiff = await resolveGitDiff(
            fromDiffEntries: diffEntries
        ) {
            gitDiff
        }
        let factualSnippets = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: fileTreeContent,
            codemapBlocks: codemapBlocks,
            contentBlocks: includeFiles ? contentBlocks : [],
            gitDiff: effectiveGitDiff
        )
        applyFactualSnippets(factualSnippets, to: &snippets)

        // User Instructions Snippet
        if includeUserPrompt, !userInstructions.isEmpty {
            snippets[.userInstructions] = userInstructionsSnippet(
                userInstructions,
                includeDatetime: includeDatetimeInUserInstructions,
                renderingDate: renderingDate
            )
        }

        // --- Build Final String ---
        let clipboardContent = PromptAssemblyBuilder.build(
            order: promptSectionsOrder,
            disabled: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets
        )

        // NEW: Prepend title block if provided and not generic
        let prefix = Self.titleSnippet(for: tabTitle) ?? ""
        return prefix + clipboardContent
    }

    static func generateClipboardContent(
        metaInstructions: [MetaInstruction],
        userInstructions: String,
        files: [ResolvedPromptFileEntry],
        fileTreeContent: String?,
        gitDiff: String? = nil,
        includeSavedPrompts: Bool,
        includeFiles: Bool,
        includeUserPrompt: Bool,
        filePathDisplay: FilePathDisplay,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot] = [:],
        includeDatetimeInUserInstructions: Bool = false,
        renderingDate: Date? = nil,
        promptSectionsOrder: [PromptSection],
        disabledPromptSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        tabTitle: String? = nil,
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) async -> String {
        var snippets: [PromptSection: String] = [:]

        let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
        let (codemapBlocks, contentBlocks) = generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay, codemapSnapshots: codemapSnapshots, displayPathResolver: displayPathResolver)

        if includeSavedPrompts, let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
            snippets[.metaPrompts] = metaSnippet
        }

        let effectiveGitDiff = await resolveGitDiff(
            fromDiffEntries: diffEntries
        ) {
            gitDiff
        }
        let factualSnippets = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: fileTreeContent,
            codemapBlocks: codemapBlocks,
            contentBlocks: includeFiles ? contentBlocks : [],
            gitDiff: effectiveGitDiff
        )
        applyFactualSnippets(factualSnippets, to: &snippets)

        if includeUserPrompt, !userInstructions.isEmpty {
            snippets[.userInstructions] = userInstructionsSnippet(
                userInstructions,
                includeDatetime: includeDatetimeInUserInstructions,
                renderingDate: renderingDate
            )
        }

        let clipboardContent = PromptAssemblyBuilder.build(
            order: promptSectionsOrder,
            disabled: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets
        )

        let prefix = Self.titleSnippet(for: tabTitle) ?? ""
        return prefix + clipboardContent
    }

    private static func selectedPath(
        for entry: ResolvedPromptFileEntry,
        filePathDisplay: FilePathDisplay,
        hasMultipleRoots: Bool
    ) -> String {
        if filePathDisplay == .relative {
            if hasMultipleRoots,
               let rootFolderPath = entry.rootFolderPath,
               !rootFolderPath.isEmpty
            {
                let rootFolderName = (StandardizedPath.absolute(rootFolderPath) as NSString).lastPathComponent
                return rootFolderName.isEmpty ? entry.file.relativePath : "\(rootFolderName)/\(entry.file.relativePath)"
            }
            return entry.file.relativePath
        }
        return entry.file.fullPath
    }

    private static func renderingDiffValues(
        _ entries: [ResolvedPromptFileEntry]
    ) -> [PromptRenderingDiffValue] {
        entries.map { entry in
            PromptRenderingDiffValue(content: entry.loadedContent, ranges: entry.lineRanges)
        }
    }

    private static func renderingDiffValues(
        _ entries: [PromptFileEntry]
    ) async -> [PromptRenderingDiffValue] {
        var values: [PromptRenderingDiffValue] = []
        values.reserveCapacity(entries.count)
        for entry in entries {
            await values.append(
                PromptRenderingDiffValue(
                    content: entry.file.latestContent,
                    ranges: entry.ranges
                )
            )
        }
        return values
    }

    private static func renderingFileValues(
        _ entries: [ResolvedPromptFileEntry],
        filePathDisplay: FilePathDisplay,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot],
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)?
    ) -> [PromptRenderingFileValue] {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        return entries.map { entry in
            let displayPath = displayPathResolver?(entry)
                ?? selectedPath(for: entry, filePathDisplay: filePathDisplay, hasMultipleRoots: hasMultipleRoots)
            let codemapText: String? = if entry.isCodemap,
                                          let api = codemapSnapshots[entry.file.id]?.fileAPI
            {
                api.getFullAPIDescription(displayPath: displayPath)
            } else {
                nil
            }
            return PromptRenderingFileValue(
                displayPath: displayPath,
                fileName: entry.file.name,
                content: entry.loadedContent,
                ranges: entry.lineRanges,
                codemapText: codemapText
            )
        }
    }

    private static func renderingFileValues(
        _ entries: [PromptFileEntry],
        filePathDisplay: FilePathDisplay
    ) async -> [PromptRenderingFileValue] {
        let hasMultipleRoots = Set(entries.map(\.file.rootFolderPath)).count > 1
        var values: [PromptRenderingFileValue] = []
        values.reserveCapacity(entries.count)

        for entry in entries {
            let file = entry.file
            let displayPath: String = if filePathDisplay == .relative {
                hasMultipleRoots ? file.uniqueRelativePath : file.relativePath
            } else {
                file.fullPath
            }
            let codemapText: String? = if entry.isCodemap, let api = file.fileAPI {
                api.getFullAPIDescription(displayPath: displayPath)
            } else {
                nil
            }
            let content = codemapText == nil ? await file.latestContent : nil
            values.append(
                PromptRenderingFileValue(
                    displayPath: displayPath,
                    fileName: file.name,
                    content: content,
                    ranges: entry.ranges,
                    codemapText: codemapText
                )
            )
        }

        return values
    }

    private static func applyFactualSnippets(
        _ factual: PromptRenderedFactualSnippets,
        to snippets: inout [PromptSection: String]
    ) {
        if let fileMap = factual.fileMap {
            snippets[.fileMap] = fileMap
        }
        if let fileContents = factual.fileContents {
            snippets[.fileContents] = fileContents
        }
        if let gitDiff = factual.gitDiff {
            snippets[.gitDiff] = gitDiff
        }
    }

    private static func userInstructionsSnippet(
        _ userInstructions: String,
        includeDatetime: Bool,
        renderingDate: Date?
    ) -> String {
        if includeDatetime {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let dateString = dateFormatter.string(from: renderingDate ?? Date())
            return """
            <user_instructions date="\(dateString)">
            \(userInstructions)
            </user_instructions>

            """
        }
        return """
        <user_instructions>
        \(userInstructions)
        </user_instructions>

        """
    }

    // MARK: - Shared builder for <meta prompt> blocks

    /// Builds a formatted string containing all meta prompts in XML format
    /// Returns nil if the meta instructions array is empty
    private static func buildMetaPromptsSnippet(_ metas: [MetaInstruction]) -> String? {
        guard !metas.isEmpty else { return nil }
        var snippet = ""
        for (index, meta) in metas.enumerated() {
            snippet += """
            <meta prompt \(index + 1) = "\(meta.title)">
            \(meta.content)
            </meta prompt \(index + 1)>

            """
        }
        return snippet
    }
}
