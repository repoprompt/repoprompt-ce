import SwiftTreeSitter
import SwiftUI

struct FilePreviewPopover: View {
    let file: FileViewModel
    let fileSlices: [LineRange]?
    let codemapEntry: WorkspaceCodemapUIPresentationEntry?
    let fileManager: WorkspaceFilesViewModel
    @Binding var showPreview: Bool

    @State private var previewContent: String = "Loading..."
    @State private var previewHighlightRanges: [NamedRange]? = nil
    @State private var loadingTask: Task<Void, Never>? = nil // Task handle
    @State private var showSlicesOnly: Bool = true // Default to showing slices if available
    @State private var viewRefreshID = UUID() // Force view refresh
    @State private var previewMode: FilePreviewMode = .syntaxHighlighted
    @State private var statusMessage: String? = nil
    @State private var codemapLogicalPath: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header with file path and controls
            headerView

            // Status banner for SVG safety or truncation warnings
            if let message = statusMessage {
                statusBannerView(message: message)
            }

            // Main content area
            contentView
        }
        .frame(width: 1000, height: 800)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.1))
        .onAppear {
            reloadPreview()
        }
        .onDisappear {
            // Cancel the loading task if the popover is dismissed
            loadingTask?.cancel()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text(codemapLogicalPath ?? file.relativePath)
                .font(.headline)
            Spacer()
            // Show toggle if file has slices
            if let slices = fileSlices, !slices.isEmpty {
                Toggle(isOn: $showSlicesOnly) {
                    Text("Show slices only")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .onChange(of: showSlicesOnly) { _, _ in
                    reloadPreview()
                }
            }
        }
        .padding()
    }

    private func statusBannerView(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var contentView: some View {
        switch previewMode {
        case .disabled:
            // Show disabled state with message
            disabledPreviewView
        case .plainText, .syntaxHighlighted:
            // Show content (plain or highlighted based on available ranges)
            if previewContent != "Loading..." {
                textPreviewView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var disabledPreviewView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Preview Disabled")
                .font(.title2)
                .fontWeight(.semibold)
            Text(previewContent)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Open the file in your editor to view its contents safely.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var textPreviewView: some View {
        // Only use syntax highlighting if mode allows and ranges are available
        if previewMode == .syntaxHighlighted,
           let ranges = previewHighlightRanges, !ranges.isEmpty
        {
            HighlightedTextKitView(
                text: $previewContent,
                highlightRanges: ranges,
                isEditable: false // Previews are read-only
            )
            .id(viewRefreshID)
        } else {
            // Plain text view - safer for large SVGs
            TextKitView(
                text: $previewContent,
                isEditable: false, // Previews are read-only
                isSpellCheckEnabled: false,
                useMonospacedFont: true // Ensure monospaced font for code
            )
            .id(viewRefreshID)
        }
    }

    private func reloadPreview() {
        // Cancel any previous task before starting a new one
        loadingTask?.cancel()

        loadingTask = Task {
            if let codemapEntry {
                await MainActor.run {
                    codemapLogicalPath = codemapEntry.logicalPath.displayPath
                }
                let disposition = await fileManager.codemapPreview(for: file.id)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    switch disposition {
                    case let .ready(entry):
                        previewContent = entry.text
                        codemapLogicalPath = entry.logicalPath.displayPath
                        statusMessage = nil
                    case let .unavailable(coverage, _):
                        previewContent = "Codemap unavailable for this file."
                        statusMessage = Self.codemapStatusMessage(for: coverage)
                    case .revoked:
                        previewContent = "Codemap preview was revoked because the workspace or selection changed."
                        statusMessage = "Preview revoked"
                    }
                    previewHighlightRanges = nil
                    previewMode = .syntaxHighlighted
                    viewRefreshID = UUID()
                }
                return
            }

            // Load the full content first
            let fullContent = await file.latestContent ?? "Error loading file content"
            if Task.isCancelled { return }

            // Trigger syntax highlighting only when snapshot mode needs it
            let previewSnapshot = await MainActor.run { file.previewSnapshot }
            let shouldLoadHighlight = (previewSnapshot?.mode ?? .syntaxHighlighted) == .syntaxHighlighted
            if shouldLoadHighlight {
                _ = await file.latestNamedRanges
                if Task.isCancelled { return }
            }

            // Decide whether to show slices or full content
            let shouldShowSlices = showSlicesOnly && fileSlices != nil && !(fileSlices?.isEmpty ?? true)

            if shouldShowSlices, let slices = fileSlices {
                // Get SVG safety info from previewSnapshot first
                let snapshot = await MainActor.run { file.previewSnapshot }
                let svgMode = snapshot?.mode ?? .syntaxHighlighted

                // For disabled SVGs, don't render slices at all - use snapshot message
                if svgMode == .disabled {
                    if !Task.isCancelled {
                        await MainActor.run {
                            previewMode = .disabled
                            previewContent = snapshot?.previewText ?? "[SVG preview disabled for safety]"
                            previewHighlightRanges = nil
                            statusMessage = snapshot?.statusMessage
                            viewRefreshID = UUID()
                        }
                    }
                    return
                }

                // Extract sliced content
                let assembly = FileViewModel.buildSliceAssembly(from: fullContent, ranges: slices)

                // Format slices with line ranges and descriptions (matching prompt format)
                let formattedContent = formatSlicesForDisplay(segments: assembly.segments, fileName: file.name)

                // For plainText SVGs, show content but without syntax highlighting
                let formattedRanges: [NamedRange]? = if svgMode == .syntaxHighlighted, let ext = file.fileExtension {
                    try? SyntaxManager.shared.highlight(content: formattedContent, fileExtension: ext)
                } else {
                    nil
                }

                if !Task.isCancelled {
                    await MainActor.run {
                        previewContent = formattedContent
                        previewHighlightRanges = formattedRanges
                        previewMode = svgMode
                        statusMessage = snapshot?.statusMessage
                        viewRefreshID = UUID()
                    }
                }
            } else {
                // Show full content using previewSnapshot for SVG-safe rendering
                let snapshot = await MainActor.run { file.previewSnapshot }

                if let snapshot {
                    // Use the SVG-safe snapshot
                    if !Task.isCancelled {
                        await MainActor.run {
                            previewMode = snapshot.mode
                            previewContent = snapshot.previewText
                            previewHighlightRanges = snapshot.namedRanges
                            statusMessage = snapshot.statusMessage
                            viewRefreshID = UUID()
                        }
                    }
                } else {
                    // Fallback to legacy behavior if no snapshot available
                    let loadedPreviewContent = await MainActor.run { file.previewContent ?? fullContent }
                    let loadedPreviewRanges = await MainActor.run { file.previewNamedRanges }

                    if !Task.isCancelled {
                        await MainActor.run {
                            previewMode = .syntaxHighlighted
                            previewContent = loadedPreviewContent
                            previewHighlightRanges = loadedPreviewRanges
                            statusMessage = nil
                            viewRefreshID = UUID()
                        }
                    }
                }
            }
        }
    }

    private static func codemapStatusMessage(
        for coverage: WorkspaceCodemapOperationPresentationCoverage
    ) -> String {
        switch coverage {
        case .complete:
            "No renderable codemap is available."
        case .partial:
            "Codemap coverage is partial."
        case .pending:
            "Codemap generation is pending."
        case .unavailable:
            "Codemap generation is unavailable."
        }
    }

    private func formatSlicesForDisplay(segments: [FileViewModel.SliceSegment], fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let commentPrefix = commentPrefixForExtension(ext)

        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let label = formatRange(segment.range)
            if let desc = segment.range.description, !desc.isEmpty {
                lines.append("\(commentPrefix) (lines \(label): \(desc))")
            } else {
                lines.append("\(commentPrefix) (lines \(label))")
            }
            lines.append(segment.text)
            if index != segments.count - 1 {
                lines.append("") // Add blank line between segments
            }
        }
        return lines.joined(separator: "\n")
    }

    private func commentPrefixForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift", "js", "ts", "jsx", "tsx", "c", "cpp", "cc", "cxx", "h", "hpp",
             "m", "mm", "java", "kt", "kts", "go", "rs", "cs", "php", "scala", "dart":
            "//"
        case "py", "rb", "sh", "bash", "zsh", "fish", "pl", "r", "yaml", "yml", "toml":
            "#"
        case "sql", "lua", "hs", "elm":
            "--"
        case "html", "xml", "svg":
            "<!--"
        case "css", "scss", "sass", "less":
            "/*"
        default:
            "//" // Default to C-style comments
        }
    }

    private func formatRange(_ range: LineRange) -> String {
        if range.start == range.end {
            return "\(range.start)"
        }
        return "\(range.start)-\(range.end)"
    }
}
