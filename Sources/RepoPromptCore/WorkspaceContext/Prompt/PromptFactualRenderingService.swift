import Foundation

package enum PromptFactualRenderingService {
    package static func render(
        entries: [ResolvedPromptFileEntry],
        codemaps: WorkspaceCodemapSnapshotBundle,
        fileTreeContent: String?,
        artifacts: [PromptAuthorizedArtifactPayload],
        filePathDisplay: FilePathDisplay,
        projection: FrozenWorkspacePathProjection?
    ) -> PromptFactualRenderedSections {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        var codemapBlocks: [String] = []
        var contentBlocks: [String] = []

        for artifact in artifacts where artifact.kind == .map && artifact.readability == .readable {
            guard !artifact.content.isEmpty else { continue }
            contentBlocks.append(renderFullFileBlock(
                selectedPath: artifact.displayAlias,
                startFence: codeFenceStart(for: artifact.displayAlias),
                content: artifact.content
            ))
        }

        for entry in entries where entry.role == .ordinary {
            guard !Task.isCancelled else { break }
            let displayPath: String
            if let projection {
                guard let logical = projection.logicalDisplayPath(
                    forPhysicalPath: entry.file.standardizedFullPath,
                    display: filePathDisplay
                ) else { continue }
                displayPath = logical
            } else {
                displayPath = selectedPath(
                    for: entry,
                    display: filePathDisplay,
                    hasMultipleRoots: hasMultipleRoots
                )
            }

            if entry.isCodemap {
                if let rendered = codemaps.renderedCodemap(for: entry.file, displayPath: displayPath) {
                    codemapBlocks.append(rendered.text)
                }
                continue
            }

            guard let content = entry.loadedContent else { continue }
            let fence = codeFenceStart(for: entry.file.name)
            if let ranges = entry.lineRanges, !ranges.isEmpty {
                let assembly = SliceAssemblyBuilder.build(from: content, ranges: ranges)
                contentBlocks.append(renderFileBlock(
                    selectedPath: displayPath,
                    startFence: fence,
                    content: content,
                    assembly: assembly
                ))
            } else {
                contentBlocks.append(renderFullFileBlock(
                    selectedPath: displayPath,
                    startFence: fence,
                    content: content
                ))
            }
        }

        let patches = artifacts
            .filter { $0.kind == .patch && $0.readability == .readable }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return PromptFactualRenderedSections(
            fileTreeContent: fileTreeContent,
            codemapBlocks: codemapBlocks,
            contentBlocks: contentBlocks.filter { !$0.isEmpty },
            selectedPatchText: patches.isEmpty ? nil : patches.joined(separator: "\n\n")
        )
    }

    package static func entrySummaries(
        entries: [ResolvedPromptFileEntry],
        artifacts: [PromptAuthorizedArtifactPayload],
        display: FilePathDisplay,
        projection: FrozenWorkspacePathProjection?
    ) -> [PromptFactualEntrySummary] {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        let artifactSummaries = artifacts.compactMap { artifact -> PromptFactualEntrySummary? in
            guard artifact.kind == .map,
                  artifact.readability == .readable,
                  !artifact.content.isEmpty
            else { return nil }
            let fileName = (artifact.displayAlias as NSString).lastPathComponent
            return PromptFactualEntrySummary(
                fileID: artifact.artifactID,
                logicalDisplayPath: artifact.displayAlias,
                fileName: fileName,
                fileExtension: URL(fileURLWithPath: fileName).pathExtension.nilIfEmpty,
                isCodemap: false
            )
        }
        let ordinarySummaries = entries.filter { $0.role == .ordinary }.map { entry in
            let path = projection?.logicalDisplayPath(
                forPhysicalPath: entry.file.standardizedFullPath,
                display: display
            ) ?? (
                projection == nil
                    ? selectedPath(for: entry, display: display, hasMultipleRoots: hasMultipleRoots)
                    : entry.file.name
            )
            return PromptFactualEntrySummary(
                fileID: entry.file.id,
                logicalDisplayPath: path,
                fileName: entry.file.name,
                fileExtension: URL(fileURLWithPath: entry.file.name).pathExtension.nilIfEmpty,
                isCodemap: entry.isCodemap
            )
        }
        return artifactSummaries + ordinarySummaries
    }

    private static func selectedPath(
        for entry: ResolvedPromptFileEntry,
        display: FilePathDisplay,
        hasMultipleRoots: Bool
    ) -> String {
        guard display == .relative else { return entry.file.fullPath }
        if hasMultipleRoots,
           let rootFolderPath = entry.rootFolderPath,
           !rootFolderPath.isEmpty
        {
            let rootName = (StandardizedPath.absolute(rootFolderPath) as NSString).lastPathComponent
            if !rootName.isEmpty { return "\(rootName)/\(entry.file.relativePath)" }
        }
        return entry.file.relativePath
    }

    private static func codeFenceStart(for fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        return ext.isEmpty ? "```" : "```\(ext)"
    }

    private static func renderFullFileBlock(
        selectedPath: String,
        startFence: String,
        content: String
    ) -> String {
        """
        File: \(selectedPath)
        \(startFence)
        \(content)
        ```
        """
    }

    private static func renderFileBlock(
        selectedPath: String,
        startFence: String,
        content _: String,
        assembly: WorkspaceSliceAssembly
    ) -> String {
        if assembly.isFullFile {
            return renderFullFileBlock(
                selectedPath: selectedPath,
                startFence: startFence,
                content: assembly.combinedText
            )
        }
        var lines = ["File: \(selectedPath)"]
        for (index, segment) in assembly.segments.enumerated() {
            let range = segment.range.start == segment.range.end
                ? "\(segment.range.start)"
                : "\(segment.range.start)-\(segment.range.end)"
            if let description = segment.range.description, !description.isEmpty {
                lines.append("(lines \(range): \(description))")
            } else {
                lines.append("(lines \(range))")
            }
            lines.append(startFence)
            lines.append(segment.text)
            lines.append("```")
            if index != assembly.segments.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
