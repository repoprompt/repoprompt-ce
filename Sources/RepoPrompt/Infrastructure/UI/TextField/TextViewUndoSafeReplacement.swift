import AppKit

@MainActor
enum TextViewUndoSafeReplacement {
    static func perform(
        in textView: NSTextView,
        undoManager: UndoManager,
        mutation: () -> Void
    ) {
        textView.breakUndoCoalescing()
        mutation()

        clearUndoHistoryWhenIdle(undoManager)
    }

    private static func clearUndoHistoryWhenIdle(_ undoManager: UndoManager) {
        guard !undoManager.isUndoing, !undoManager.isRedoing else {
            DispatchQueue.main.async {
                clearUndoHistoryWhenIdle(undoManager)
            }
            return
        }

        undoManager.removeAllActions()
    }
}
