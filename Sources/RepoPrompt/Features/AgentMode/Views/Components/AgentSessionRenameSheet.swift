import SwiftUI

private extension View {
    func renameSheetControlBackground() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}

struct AgentSessionRenameSheet: View {
    @Binding var renameText: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFieldFocused: Bool
    @State private var isClearHovered = false

    private var trimmedText: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmRename() {
        if !trimmedText.isEmpty {
            onConfirm(trimmedText)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Rename Chat")
                    .font(.system(size: 14, weight: .semibold))
            }

            // Text field
            HStack(spacing: 6) {
                TextField("Enter a name…", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFieldFocused)
                    .onSubmit(confirmRename)

                if !renameText.isEmpty {
                    Button {
                        renameText = ""
                        isFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isClearHovered = $0 }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .renameSheetControlBackground()

            // Buttons
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .renameSheetControlBackground()
                .keyboardShortcut(.cancelAction)

                Button(action: confirmRename) {
                    Text("Rename")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(trimmedText.isEmpty ? .secondary : Color.accentColor)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(trimmedText.isEmpty ? 0.05 : 0.12))
                )
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
        .onAppear {
            isFieldFocused = true
        }
    }
}
