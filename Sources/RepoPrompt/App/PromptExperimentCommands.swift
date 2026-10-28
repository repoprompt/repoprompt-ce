#if DEBUG
    import SwiftUI

    /// DEBUG-only Window-menu entry for the standalone Prompt Experiments Studio.
    ///
    /// Gives experiments created through external MCP/CLI clients a visible approval surface
    /// outside Agent Mode transcripts. Release builds do not ship the Prompt Experiments lab.
    struct PromptExperimentCommands: Commands {
        var body: some Commands {
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Prompt Experiments…") {
                    WindowStatesManager.shared.promptExperimentStudioWindowCoordinator.open()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }
    }
#endif
