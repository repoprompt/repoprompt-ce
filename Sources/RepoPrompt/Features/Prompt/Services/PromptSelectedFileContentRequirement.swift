import Foundation

/// How prompt packaging treats explicitly selected full/slice files it cannot resolve or read.
enum PromptSelectedFileContentPolicy: Equatable {
    /// Interactive packaging: unresolved or unreadable selections are skipped silently.
    case bestEffort
    /// Oracle packaging: await applied workspace ingress for the explicit selection, then fail
    /// closed instead of sending a prompt that is missing explicitly selected file contents.
    case required
}

/// Raised when an Oracle prompt would omit explicitly selected full/slice file contents.
struct PromptSelectedFileContentUnavailableError: LocalizedError, Equatable {
    static let maxListedPaths = 20

    let paths: [String]

    var errorDescription: String? {
        let listed = paths.prefix(Self.maxListedPaths).map { "- \($0)" }.joined(separator: "\n")
        let overflow = paths.count > Self.maxListedPaths
            ? "\n- …and \(paths.count - Self.maxListedPaths) more"
            : ""
        return """
        Oracle send aborted: \(paths.count) selected file(s) could not be resolved or read, so their contents \
        would be missing from the prompt:
        \(listed)\(overflow)
        The workspace file index may still be loading. Retry shortly, or check the selection with \
        manage_selection (op=get) and remove paths that no longer exist.
        """
    }
}

/// Oracle-only guard around prompt preassembly. Explicit full/slice selections are required
/// content; manual codemaps, folder descendants, and authorized git artifacts stay best-effort.
enum PromptSelectedFileContentRequirement {
    /// Bounded so a stalled watcher cannot hold an Oracle send; unresolved paths still fail closed.
    static let ingressWaitTimeout: Duration = .seconds(15)

    /// Explicit full-file and slice paths from a (physical) selection, in stable order.
    static func explicitContentPaths(in selection: StoredSelection) -> [String] {
        let slicePaths = StoredSelectionPathNormalization.orderedSlicePaths(selection.slices)
            .filter { selection.slices[$0]?.isEmpty == false }
        var seen = Set<String>()
        return (selection.selectedPaths + slicePaths).filter { seen.insert($0).inserted }
    }

    /// Awaits applied workspace ingress for the explicit selection before entry resolution so a
    /// freshly switched or still-settling catalog does not silently drop selected files.
    /// Timeouts fall through to resolution; cancellation propagates.
    static func awaitAppliedIngress(
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        store: WorkspaceFileContextStore,
        timeout: Duration = ingressWaitTimeout
    ) async throws {
        let paths = explicitContentPaths(in: lookupContext.physicalizeSelection(selection))
        guard !paths.isEmpty else { return }
        do {
            _ = try await store.awaitAppliedIngressForExplicitRequests(
                userPaths: paths,
                fallbackScope: lookupContext.rootScope.excludingWorkspaceGitData,
                timeout: timeout
            )
        } catch is WorkspaceAppliedIngressWaitError {
            // Bounded wait expired; resolution below still fails closed for unresolved paths.
        }
    }

    /// Explicitly selected full/slice paths that preassembly could not resolve or read.
    static func unavailablePaths(in result: PromptContextPreAssemblyResult) -> [String] {
        let directPaths = Set(
            explicitContentPaths(in: result.physicalSelection)
                .compactMap(StoredSelectionPathNormalization.standardizedPath)
        )
        let unreadDirectEntries = result.entries.filter { entry in
            entry.role == .ordinary
                && entry.mode != .codemap
                && entry.loadedContent == nil
                && directPaths.contains(entry.file.standardizedFullPath)
        }
        let unreadPaths = unreadDirectEntries.map { entry in
            result.displayPath(for: entry) ?? entry.file.standardizedFullPath
        }
        var seen = Set<String>()
        return (result.missingPaths + result.invalidPaths + unreadPaths).filter { seen.insert($0).inserted }
    }

    static func validate(
        _ result: PromptContextPreAssemblyResult,
        config: PromptContextResolved
    ) throws {
        guard config.includeFiles else { return }
        let paths = unavailablePaths(in: result)
        guard paths.isEmpty else {
            throw PromptSelectedFileContentUnavailableError(paths: paths)
        }
    }
}
