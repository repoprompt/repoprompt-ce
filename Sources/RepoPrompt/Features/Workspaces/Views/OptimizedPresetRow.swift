import RepoPromptFileSystem
import SwiftUI

/// Optimized preset row that minimizes re-renders
struct OptimizedPresetRow: View {
    let preset: WorkspacePreset
    let index: Int
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Reorder buttons
                HStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                    .disabled(isFirst)
                    .opacity(isFirst ? 0.3 : 0.7)
                    .hoverTooltip("Move preset up")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                    .disabled(isLast)
                    .opacity(isLast ? 0.3 : 0.7)
                    .hoverTooltip("Move preset down")
                }
                .padding(.trailing, 8)

                Text("[\(index + 1)] \(preset.name)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .medium))

                Spacer()

                // Action buttons
                Button(action: onSwitch) {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Switch to preset")

                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Rename preset")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Delete preset")
            }

            // File list preview
            PresetFileListPreview(filePaths: preset.selectedFilePaths)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.85))
        )
    }
}

/// Separate component for file list to minimize re-renders
struct PresetFileListPreview: View {
    let filePaths: [String]
    private let maxFiles = 3
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        if !filePaths.isEmpty {
            let displayedFiles = filePaths.prefix(maxFiles)
            let additionalFiles = filePaths.count > maxFiles ? filePaths.count - maxFiles : 0

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(displayedFiles), id: \.self) { file in
                    Text(file)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if additionalFiles > 0 {
                    Text("... and \(additionalFiles) more file\(additionalFiles == 1 ? "" : "s")")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        } else {
            Text("No files selected.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
        }
    }
}
