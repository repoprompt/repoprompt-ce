import SwiftUI

struct AgentResolvedFilePreviewPopover: View {
    let row: AgentContextExportRow
    @ObservedObject var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator

    private var displayText: String {
        previewCoordinator.displayText(for: row)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(row.displayPath)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding()
            TextKitView(
                text: .constant(displayText),
                isEditable: false,
                isSpellCheckEnabled: false,
                useMonospacedFont: true,
                // Keep this wired to the coordinator: TextKitView avoids overwriting
                // first-responder AppKit text unless its external update tick changes.
                externalUpdateTick: previewCoordinator.contentRevision
            )
        }
        .frame(width: 900, height: 650)
    }
}
