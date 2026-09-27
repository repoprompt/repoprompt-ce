import Foundation

/// An automatic-selection prerequisite (from `read_file` or an eligible `file_search`) that ended
/// deferred or invalidated rejects a selection-dependent tool without rolling back earlier
/// selection or binding effects.
/// Unlike cancellation, it tells the caller that the tool did not run because of the
/// selection state. Context Builder keeps its own `MCPContextBuilderSelectionPrerequisiteError`.
enum MCPSelectionPrerequisiteError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case deferred
    case invalidated

    var description: String {
        switch self {
        case .deferred:
            "selection_prerequisite_deferred: The tool did not run because its selection prerequisite was deferred: automatic selection from an earlier read_file or file_search had not reached the required selection state. Earlier selection effects were kept. Check this connection's tab binding and that tab's selection state; this result can repeat while that selection has not reached the required state."
        case .invalidated:
            "selection_prerequisite_invalidated: The tool did not run because its selection prerequisite was invalidated: automatic selection from an earlier read_file or file_search was invalidated before the prerequisite completed. Earlier selection effects were kept. Check this connection's tab binding and that tab's selection state."
        }
    }

    var errorDescription: String? {
        description
    }
}
