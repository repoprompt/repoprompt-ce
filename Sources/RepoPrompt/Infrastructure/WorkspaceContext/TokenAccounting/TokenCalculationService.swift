//
//  TokenCalculationService.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-21.
//

import Combine
import Foundation

/// Info for each file/folder's tokens
/// Stores both full file tokens and codemap tokens to support different rendering modes.
struct TokenInfo: Identifiable, Equatable {
    let id = UUID()
    /// The "display" token count based on current rendering mode (full, slice, or codemap)
    let count: Int
    /// Always stores the full file content tokens (for `fullTokens()` lookups)
    let fullCount: Int
    /// Stores the codemap token count if available (0 if no codemap)
    let codemapCount: Int
    let formatted: String
    let percentage: Double

    init(count: Int, fullCount: Int? = nil, codemapCount: Int = 0, totalTokens: Int) {
        self.count = count
        self.fullCount = fullCount ?? count
        self.codemapCount = codemapCount
        formatted = String(format: "%.2fk", Double(count) / 1000.0)
        percentage = totalTokens > 0 ? Double(count) / Double(totalTokens) : 0
    }
}

/// High-level struct for returning all relevant token results.
/// Now includes codeMapFileCount and codeMapTokenCount.
struct TokenCalculationResult {
    let totalTokenCount: Int
    // NEW – raw integer count of tokens for **files only**
    let totalTokenCountFilesOnly: Int
    let fileTokenInfo: [UUID: TokenInfo]
    let folderTokenInfo: [String: TokenInfo]
    let tokenCountString: String
    let tokenCountFilesOnlyString: String
    let charCount: Int
    let fileTreeContent: String
    let fileTreeTokenCount: Double
    let fileTreeTokenCountRaw: Int
    let codeMapContent: String // NEW – raw code-map block text
    let codeMapFileCount: Int
    let codeMapTokenCount: Int
}

struct TokenComponentBreakdown {
    let prompt: Int
    let duplicatePrompt: Int
    let instructions: Int
    let fileTree: Int
    let gitDiff: Int
    let metadata: Int

    var promptDisplay: Int {
        prompt + duplicatePrompt
    }

    var other: Int {
        metadata
    }

    var totalNonFile: Int {
        prompt + duplicatePrompt + instructions + fileTree + gitDiff + metadata
    }
}

struct PromptEntriesEvaluation {
    enum RenderMode: String {
        case full
        case slice
        case codemap
    }

    struct EntryResult {
        let fileID: UUID
        let renderMode: RenderMode
        let displayTokens: Int
        let fullTokens: Int
        let codemapTokens: Int
    }

    let entryResultsByFileID: [UUID: EntryResult]
    let totalDisplayTokens: Int
    let totalContentTokens: Int
    let fullCount: Int
    let sliceCount: Int
    let codemapCount: Int
    let fullTokens: Int
    let sliceTokens: Int
    let codemapTokens: Int
    let fileTokenInfo: [UUID: TokenInfo]
    let folderTokenInfo: [String: TokenInfo]
    let charCount: Int
    let codeMapContent: String
    let codeMapFileCount: Int
    let codeMapTokenCount: Int

    static let empty = PromptEntriesEvaluation(
        entryResultsByFileID: [:],
        totalDisplayTokens: 0,
        totalContentTokens: 0,
        fullCount: 0,
        sliceCount: 0,
        codemapCount: 0,
        fullTokens: 0,
        sliceTokens: 0,
        codemapTokens: 0,
        fileTokenInfo: [:],
        folderTokenInfo: [:],
        charCount: 0,
        codeMapContent: "",
        codeMapFileCount: 0,
        codeMapTokenCount: 0
    )
}

/// An actor for gathering file contents and running token calculations.
actor TokenCalculationService {
    /// Hold the currently running calculation task.
    private var currentCalculationTask: Task<TokenCalculationResult, Never>?

    /// Compute tokens from raw text using a cheap UTF-8 byte count plus a safety multiplier.
    @inline(__always)
    static func estimateTokens(for text: String) -> Int {
        let bytes = text.utf8.count
        return Int((Double(bytes) / 4.0) * 1.05)
    }

    /// Middle-truncate text that exceeds `maxTokens`, keeping equal halves from head and tail
    /// with a marker inserted between them. Deterministic and idempotent.
    ///
    /// Uses a simple 4-bytes-per-token heuristic. Cut points are aligned to grapheme
    /// cluster boundaries to avoid splitting characters.
    static func middleTruncate(
        text: String,
        maxTokens: Int,
        marker: String = "\n\n[content truncated]\n\n"
    ) -> String {
        let textBytes = text.utf8.count
        guard textBytes / 4 > maxTokens else { return text }

        let maxBytes = maxTokens * 4
        let markerBytes = marker.utf8.count
        let contentBytes = max(0, maxBytes - markerBytes)
        guard contentBytes > 0 else { return marker }

        let headBytes = contentBytes / 2
        let tailBytes = contentBytes - headBytes

        // Find grapheme-safe cut points via the UTF-8 view.
        // Walk backward/forward when a byte offset lands inside a multi-byte cluster.
        let utf8 = text.utf8
        let headEnd = utf8.index(utf8.startIndex, offsetBy: min(headBytes, utf8.count))
        let headCut = Self.alignedIndex(headEnd, in: text, direction: .backward)

        let tailStart = utf8.index(utf8.endIndex, offsetBy: -min(tailBytes, utf8.count))
        let tailCut = Self.alignedIndex(tailStart, in: text, direction: .forward)

        let head = text[text.startIndex ..< headCut]
        let tail = text[tailCut ..< text.endIndex]
        return String(head) + marker + String(tail)
    }

    private enum AlignDirection { case forward, backward }

    /// Walk a UTF-8 index backward or forward until it aligns to a grapheme cluster boundary.
    private static func alignedIndex(
        _ utf8Index: String.UTF8View.Index,
        in text: String,
        direction: AlignDirection
    ) -> String.Index {
        let utf8 = text.utf8
        var cursor = utf8Index
        switch direction {
        case .backward:
            while cursor > utf8.startIndex {
                if let aligned = String.Index(cursor, within: text) {
                    return aligned
                }
                cursor = utf8.index(before: cursor)
            }
            return text.startIndex
        case .forward:
            while cursor < utf8.endIndex {
                if let aligned = String.Index(cursor, within: text) {
                    return aligned
                }
                cursor = utf8.index(after: cursor)
            }
            return text.endIndex
        }
    }

    /// Join an array of strings with newline separators using reserved capacity to avoid churn.
    @inline(__always)
    private static func joinWithNewlines(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        if parts.count == 1 {
            return parts[0]
        }

        var totalBytes = 0
        for part in parts {
            totalBytes += part.utf8.count
        }
        totalBytes += parts.count - 1

        var joined = String()
        joined.reserveCapacity(totalBytes)

        for index in 0 ..< parts.count {
            joined.append(parts[index])
            if index != parts.count - 1 {
                joined.append("\n")
            }
        }

        return joined
    }

    static func calculateComponentBreakdown(
        promptText: String,
        selectedInstructionsText: String,
        fileTreeText: String,
        gitDiffText: String?,
        metadataText: String?,
        duplicateUserInstructionsAtTop: Bool
    ) -> TokenComponentBreakdown {
        let promptTokens = estimateTokens(for: promptText)
        let duplicatePromptTokens = duplicateUserInstructionsAtTop ? promptTokens : 0
        let instructionsTokens = estimateTokens(for: selectedInstructionsText)
        let fileTreeTokens = fileTreeText.isEmpty ? 0 : estimateTokens(for: fileTreeText)
        let gitDiffTokens = gitDiffText.map(estimateTokens(for:)) ?? 0
        let metadataTokens = metadataText.map(estimateTokens(for:)) ?? 0
        return TokenComponentBreakdown(
            prompt: promptTokens,
            duplicatePrompt: duplicatePromptTokens,
            instructions: instructionsTokens,
            fileTree: fileTreeTokens,
            gitDiff: gitDiffTokens,
            metadata: metadataTokens
        )
    }

    func evaluatePromptEntries(
        _ fileEntries: [PromptFileEntrySnapshot]
    ) -> PromptEntriesEvaluation {
        Self.evaluatePromptEntries(fileEntries)
    }

    private static func evaluatePromptEntries(
        _ fileEntries: [PromptFileEntrySnapshot]
    ) -> PromptEntriesEvaluation {
        let contentEntries = fileEntries.filter { !$0.isCodemapRequested }
        let codemapEntries = fileEntries.filter { $0.isCodemapRequested && $0.codeMapContent != nil }
        let unresolvedCodemapEntries = fileEntries.filter { $0.isCodemapRequested && $0.codeMapContent == nil }

        let sliceAssemblies = Self.buildSliceAssemblies(for: contentEntries)
        if Task.isCancelled {
            return PromptEntriesEvaluation.empty
        }

        let codeMapComposed: (content: String, fileCount: Int, tokenCount: Int) = {
            var snippets: [String] = []
            var fileCount = 0
            var tokenCount = 0
            for entry in codemapEntries {
                guard let content = entry.codeMapContent, !content.isEmpty else { continue }
                snippets.append(content)
                fileCount += 1
                tokenCount += entry.availableCodeMapTokenCount
            }
            return (Self.joinWithNewlines(snippets), fileCount, tokenCount)
        }()

        let aggregated = Self.calculateEntryTokens(
            contentEntries: contentEntries,
            codemapEntries: codemapEntries,
            unresolvedCodemapEntries: unresolvedCodemapEntries,
            sliceAssemblies: sliceAssemblies
        )
        return PromptEntriesEvaluation(
            entryResultsByFileID: aggregated.entryResultsByFileID,
            totalDisplayTokens: aggregated.totalContentTokens + codeMapComposed.tokenCount,
            totalContentTokens: aggregated.totalContentTokens,
            fullCount: aggregated.fullCount,
            sliceCount: aggregated.sliceCount,
            codemapCount: aggregated.codemapCount,
            fullTokens: aggregated.fullTokens,
            sliceTokens: aggregated.sliceTokens,
            codemapTokens: aggregated.codemapTokens,
            fileTokenInfo: aggregated.fileTokenInfo,
            folderTokenInfo: aggregated.folderTokenInfo,
            charCount: aggregated.charCount,
            codeMapContent: codeMapComposed.content,
            codeMapFileCount: codeMapComposed.fileCount,
            codeMapTokenCount: codeMapComposed.tokenCount
        )
    }

    /// Calculate token statistics. Heavy work is offloaded and cancellation is checked.
    func calculatePromptStats(
        snapshot: TokenCalculationSnapshot
    ) async -> TokenCalculationResult {
        currentCalculationTask?.cancel()

        currentCalculationTask = Task.detached {
            let evaluation = Self.evaluatePromptEntries(snapshot.promptEntries)
            if Task.isCancelled {
                return Self.defaultResult
            }

            let fileTreeContent: String = switch snapshot.fileTree {
            case .none:
                ""
            case let .rendered(content):
                content
            case let .snapshot(treeSnapshot):
                CodeMapExtractor.generateFileTree(using: treeSnapshot)
            }
            let fileTreeTokens = fileTreeContent.isEmpty ? 0 : Self.estimateTokens(for: fileTreeContent)
            let components = Self.calculateComponentBreakdown(
                promptText: snapshot.promptText,
                selectedInstructionsText: snapshot.selectedInstructionsText,
                fileTreeText: fileTreeContent,
                gitDiffText: nil,
                metadataText: nil,
                duplicateUserInstructionsAtTop: snapshot.duplicateUserInstructionsAtTop
            )

            let finalTotalTokens = evaluation.totalDisplayTokens + components.totalNonFile
            let finalCharCount = evaluation.charCount
                + snapshot.promptText.count
                + (snapshot.duplicateUserInstructionsAtTop ? snapshot.promptText.count : 0)
                + snapshot.selectedInstructionsText.count

            return TokenCalculationResult(
                totalTokenCount: finalTotalTokens,
                totalTokenCountFilesOnly: evaluation.totalContentTokens,
                fileTokenInfo: evaluation.fileTokenInfo,
                folderTokenInfo: evaluation.folderTokenInfo,
                tokenCountString: String(format: "%.2fk", Double(finalTotalTokens) / 1000.0),
                tokenCountFilesOnlyString: String(format: "%.2fk", Double(evaluation.totalContentTokens) / 1000.0),
                charCount: finalCharCount,
                fileTreeContent: fileTreeContent,
                fileTreeTokenCount: Double(fileTreeTokens) / 1000.0,
                fileTreeTokenCountRaw: fileTreeTokens,
                codeMapContent: evaluation.codeMapContent,
                codeMapFileCount: evaluation.codeMapFileCount,
                codeMapTokenCount: evaluation.codeMapTokenCount
            )
        }

        let result = await currentCalculationTask!.value
        currentCalculationTask = nil
        return result
    }

    /// Cancel any pending token calculations.
    func shutdown() async {
        currentCalculationTask?.cancel()
        _ = await currentCalculationTask?.value
        currentCalculationTask = nil
    }

    private static func buildSliceAssemblies(
        for entries: [PromptFileEntrySnapshot]
    ) -> [UUID: FileViewModel.SliceAssembly] {
        let candidates = entries.filter { entry in
            if let ranges = entry.ranges {
                return !ranges.isEmpty
            }
            return false
        }
        guard !candidates.isEmpty else { return [:] }

        var result: [UUID: FileViewModel.SliceAssembly] = [:]
        result.reserveCapacity(candidates.count)
        for entry in candidates {
            if Task.isCancelled {
                break
            }
            guard let content = entry.loadedContent else { continue }
            result[entry.fileID] = FileViewModel.buildSliceAssembly(from: content, ranges: entry.ranges)
        }
        return result
    }

    private struct AggregatedEntryTokens {
        let entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]
        let totalContentTokens: Int
        let fullCount: Int
        let sliceCount: Int
        let codemapCount: Int
        let fullTokens: Int
        let sliceTokens: Int
        let codemapTokens: Int
        let fileTokenInfo: [UUID: TokenInfo]
        let folderTokenInfo: [String: TokenInfo]
        let charCount: Int
    }

    private static func calculateEntryTokens(
        contentEntries: [PromptFileEntrySnapshot],
        codemapEntries: [PromptFileEntrySnapshot],
        unresolvedCodemapEntries: [PromptFileEntrySnapshot],
        sliceAssemblies: [UUID: FileViewModel.SliceAssembly]
    ) -> AggregatedEntryTokens {
        var entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult] = [:]
        var folderTokenAccum: [String: Int] = [:]
        var totalChars = 0
        var fullCount = 0
        var sliceCount = 0
        var codemapCount = 0
        var fullTokens = 0
        var sliceTokens = 0
        var codemapTokens = 0

        for entry in contentEntries {
            if Task.isCancelled {
                break
            }

            let assembly = sliceAssemblies[entry.fileID]
            let renderMode: PromptEntriesEvaluation.RenderMode
            let displayTokens: Int
            let fullTokenCount: Int
            let charCountContribution: Int
            if let assembly {
                renderMode = .slice
                displayTokens = Self.estimateTokens(for: assembly.combinedText)
                fullTokenCount = entry.cachedFullTokenCount
                    ?? entry.loadedContent.map(Self.estimateTokens(for:))
                    ?? displayTokens
                charCountContribution = assembly.totalCharacters
                sliceCount += 1
                sliceTokens += displayTokens
            } else {
                renderMode = .full
                let estimatedTokens = entry.loadedContent.map(Self.estimateTokens(for:))
                let resolvedTokens = entry.cachedFullTokenCount ?? estimatedTokens ?? 0
                displayTokens = resolvedTokens
                fullTokenCount = resolvedTokens
                charCountContribution = entry.loadedContent?.count
                    ?? (resolvedTokens > 0 ? Int(Double(resolvedTokens) * 4.0) : 0)
                fullCount += 1
                fullTokens += displayTokens
            }

            entryResultsByFileID[entry.fileID] = .init(
                fileID: entry.fileID,
                renderMode: renderMode,
                displayTokens: displayTokens,
                fullTokens: fullTokenCount,
                codemapTokens: entry.availableCodeMapTokenCount
            )
            totalChars += charCountContribution
            let folderPath = extractFolderPath(from: entry.relativePath)
            folderTokenAccum[folderPath, default: 0] += displayTokens
        }

        for entry in codemapEntries {
            if Task.isCancelled {
                break
            }

            let apiTokens = entry.availableCodeMapTokenCount
            codemapCount += 1
            codemapTokens += apiTokens
            entryResultsByFileID[entry.fileID] = .init(
                fileID: entry.fileID,
                renderMode: .codemap,
                displayTokens: apiTokens,
                fullTokens: entry.cachedFullTokenCount ?? entry.loadedContent.map(Self.estimateTokens(for:)) ?? 0,
                codemapTokens: apiTokens
            )
            let folderPath = extractFolderPath(from: entry.relativePath)
            folderTokenAccum[folderPath, default: 0] += apiTokens
        }

        for entry in unresolvedCodemapEntries {
            if entryResultsByFileID[entry.fileID] != nil {
                continue
            }
            codemapCount += 1
            entryResultsByFileID[entry.fileID] = .init(
                fileID: entry.fileID,
                renderMode: .codemap,
                displayTokens: 0,
                fullTokens: entry.cachedFullTokenCount ?? entry.loadedContent.map(Self.estimateTokens(for:)) ?? 0,
                codemapTokens: 0
            )
        }

        let totalContentTokens = fullTokens + sliceTokens
        let combinedDisplayTokens = totalContentTokens + codemapTokens
        let fileTokenInfo = entryResultsByFileID.reduce(into: [UUID: TokenInfo]()) { partial, item in
            let result = item.value
            partial[item.key] = TokenInfo(
                count: result.displayTokens,
                fullCount: result.fullTokens,
                codemapCount: result.codemapTokens,
                totalTokens: combinedDisplayTokens
            )
        }
        let folderTokenInfo = folderTokenAccum.reduce(into: [String: TokenInfo]()) { partial, item in
            partial[item.key] = TokenInfo(count: item.value, totalTokens: combinedDisplayTokens)
        }

        return AggregatedEntryTokens(
            entryResultsByFileID: entryResultsByFileID,
            totalContentTokens: totalContentTokens,
            fullCount: fullCount,
            sliceCount: sliceCount,
            codemapCount: codemapCount,
            fullTokens: fullTokens,
            sliceTokens: sliceTokens,
            codemapTokens: codemapTokens,
            fileTokenInfo: fileTokenInfo,
            folderTokenInfo: folderTokenInfo,
            charCount: totalChars
        )
    }

    // NOTE: estimateTokens now lives near the top of the actor and uses utf8.count for speed.

    /// Extracts a folder path from a file's relative path.
    private static func extractFolderPath(from relativePath: String) -> String {
        let components = relativePath.split(separator: "/")
        return components.count > 1 ? components.dropLast().joined(separator: "/") : ""
    }

    /// A default result to return when a task is cancelled.
    private static var defaultResult: TokenCalculationResult {
        TokenCalculationResult(
            totalTokenCount: 0,
            totalTokenCountFilesOnly: 0,
            fileTokenInfo: [:],
            folderTokenInfo: [:],
            tokenCountString: "0.00k",
            tokenCountFilesOnlyString: "0.00k",
            charCount: 0,
            fileTreeContent: "",
            fileTreeTokenCount: 0,
            fileTreeTokenCountRaw: 0,
            codeMapContent: "",
            codeMapFileCount: 0,
            codeMapTokenCount: 0
        )
    }
}
