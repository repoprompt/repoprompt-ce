import Foundation

package enum PromptRenderingService {
    @inline(__always)
    package static func codeFenceStart(for fileName: String) -> String {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        return fileExtension.isEmpty ? "```" : "```\(fileExtension)"
    }

    package static func renderFileBlocks(
        _ values: [PromptRenderingFileValue]
    ) -> [PromptRenderedFileBlock] {
        var blocks: [PromptRenderedFileBlock] = []
        blocks.reserveCapacity(values.count)

        for (index, value) in values.enumerated() {
            if let codemapText = value.codemapText {
                blocks.append(
                    PromptRenderedFileBlock(
                        inputIndex: index,
                        text: codemapText,
                        kind: .codemap
                    )
                )
                continue
            }

            guard let content = value.content else { continue }
            let assembly = SliceAssemblyBuilder.build(from: content, ranges: value.ranges)
            let startFence = codeFenceStart(for: value.fileName)
            let text = if assembly.isFullFile {
                renderFullFileBlock(
                    displayPath: value.displayPath,
                    startFence: startFence,
                    content: assembly.combinedText
                )
            } else {
                renderSliceFileBlock(
                    displayPath: value.displayPath,
                    startFence: startFence,
                    segments: assembly.segments
                )
            }
            blocks.append(
                PromptRenderedFileBlock(
                    inputIndex: index,
                    text: text,
                    kind: .content
                )
            )
        }

        return blocks
    }

    package static func renderPartitionedFileBlocks(
        _ values: [PromptRenderingFileValue]
    ) -> PromptPartitionedFileBlocks {
        let blocks = renderFileBlocks(values)
        var codemapBlocks: [String] = []
        var contentBlocks: [String] = []
        codemapBlocks.reserveCapacity(blocks.count)
        contentBlocks.reserveCapacity(blocks.count)

        for block in blocks where !block.text.isEmpty {
            switch block.kind {
            case .codemap:
                codemapBlocks.append(block.text)
            case .content:
                contentBlocks.append(block.text)
            }
        }

        return PromptPartitionedFileBlocks(
            codemapBlocks: codemapBlocks,
            contentBlocks: contentBlocks
        )
    }

    package static func renderDiffParts(
        _ values: [PromptRenderingDiffValue]
    ) -> [String] {
        var parts: [String] = []
        parts.reserveCapacity(values.count)

        for value in values {
            guard let content = value.content, !content.isEmpty else { continue }
            let assembly = SliceAssemblyBuilder.build(from: content, ranges: value.ranges)
            let text = assembly.isFullFile
                ? assembly.combinedText
                : assembly.segments.map(\.text).joined(separator: "\n")
            if !text.isEmpty {
                parts.append(text)
            }
        }

        return parts
    }

    package static func renderSelectedDiffText(
        _ values: [PromptRenderingDiffValue]
    ) -> String? {
        let parts = renderDiffParts(values)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    package static func renderFactualSnippets(
        fileTreeContent: String?,
        codemapBlocks: [String],
        contentBlocks: [String],
        gitDiff: String?,
        envelopePolicy: PromptFactualEnvelopePolicy = .canonical
    ) -> PromptRenderedFactualSnippets {
        let codemapText = codemapBlocks.joined(separator: "\n\n")
        let fileMapBody = [fileTreeContent ?? "", codemapText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let fileMap = wrapFactualBody(
            fileMapBody,
            tag: envelopePolicy.fileMapTag,
            closeSpacing: envelopePolicy.fileMapCloseSpacing,
            terminator: envelopePolicy.fragmentTerminator
        )

        let fileContents = wrapFactualBody(
            contentBlocks.joined(separator: "\n\n"),
            tag: envelopePolicy.fileContentsTag,
            closeSpacing: envelopePolicy.fileContentsCloseSpacing,
            terminator: envelopePolicy.fragmentTerminator,
            allowEmptyBody: !contentBlocks.isEmpty
        )

        let gitDiffSnippet = wrapFactualBody(
            gitDiff ?? "",
            tag: envelopePolicy.gitDiffTag,
            closeSpacing: envelopePolicy.gitDiffCloseSpacing,
            terminator: envelopePolicy.fragmentTerminator
        )

        return PromptRenderedFactualSnippets(
            fileMap: fileMap,
            fileContents: fileContents,
            gitDiff: gitDiffSnippet
        )
    }

    private static func wrapFactualBody(
        _ body: String,
        tag: String,
        closeSpacing: PromptFactualEnvelopePolicy.WrapperCloseSpacing,
        terminator: PromptFactualEnvelopePolicy.FragmentTerminator,
        allowEmptyBody: Bool = false
    ) -> String? {
        guard allowEmptyBody || !body.isEmpty else { return nil }
        let closePrefix = switch closeSpacing {
        case .direct:
            "\n"
        case .blankLine:
            "\n\n"
        }
        let suffix = switch terminator {
        case .lineFeed:
            "\n"
        case .none:
            ""
        }
        return "<\(tag)>\n\(body)\(closePrefix)</\(tag)>\(suffix)"
    }

    private static func renderFullFileBlock(
        displayPath: String,
        startFence: String,
        content: String
    ) -> String {
        """
        File: \(displayPath)
        \(startFence)
        \(content)
        ```
        """
    }

    private static func renderSliceFileBlock(
        displayPath: String,
        startFence: String,
        segments: [WorkspaceSliceSegment]
    ) -> String {
        var lines = ["File: \(displayPath)"]
        for (index, segment) in segments.enumerated() {
            let rangeLabel = segment.range.start == segment.range.end
                ? "\(segment.range.start)"
                : "\(segment.range.start)-\(segment.range.end)"
            if let description = segment.range.description, !description.isEmpty {
                lines.append("(lines \(rangeLabel): \(description))")
            } else {
                lines.append("(lines \(rangeLabel))")
            }
            lines.append(startFence)
            lines.append(segment.text)
            lines.append("```")
            if index != segments.count - 1 {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
