import Foundation
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

enum RemoteWorkspaceVoiceFileOperation {
    case list
    case read
}

/// Reads workspace catalog entries using the same exact-path resolution as desktop file tools.
@MainActor
struct RemoteWorkspaceVoiceFiles {
    let window: WindowState
    let workspaceID: UUID

    func execute(_ operation: RemoteWorkspaceVoiceFileOperation, path: String?) async throws -> String {
        guard let workspace = window.workspaceManager.activeWorkspace,
              workspace.id == workspaceID, !window.isClosing
        else { throw RemoteWorkspaceVoiceError.workspaceClosed }
        if workspace.repoPaths.isEmpty {
            guard operation == .list, path == nil || path == "." else { throw Self.pathUnavailable }
            return try encode(["roots": [String](), "entries": [String]()])
        }
        let manager = window.workspaceManager
        let snapshot = try await manager.readyPrimaryRootSnapshot(
            workspaceID: workspaceID, expectedRepoPaths: workspace.repoPaths
        )
        let roots = snapshot.roots
        let store = window.workspaceFileContextStore
        let aliases = ClientPathFormatter.exactRootAliases(visibleRoots: roots)
        let result: [String: Any]
        if operation == .list, path == nil || path == "." {
            if let root = roots.first, roots.count == 1 {
                result = await listChildren(rootID: root.id, directory: "", displayPath: aliases[root.id] ?? root.name)
            } else {
                result = ["roots": roots.map { aliases[$0.id] ?? $0.name }]
            }
        } else {
            guard let path, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.split(separator: "/").contains("..")
            else { throw RemoteWorkspaceVoiceError.invalidToolArguments }
            let namespace = WorkspaceLookupContext.visibleWorkspace.exactFileNamespace(storeRoots: roots)
            let resolution = try await store.resolveExactExistingWorkspaceFile(
                WorkspaceExactFileInput.parse(path), namespace: namespace
            )
            switch (operation, resolution) {
            case let (.list, .directory(directory)):
                result = await listChildren(
                    rootID: directory.lookupRoot.id, directory: directory.relativePath, displayPath: directory.displayPath
                )
            case let (.read, .matched(match)):
                guard let content = try await store.readContentPrefix(
                    rootID: match.file.rootID, relativePath: match.file.standardizedRelativePath, maximumBytes: 12000
                ) else { throw Self.pathUnavailable }
                result = ["path": match.canonicalPath, "text": content.content, "truncated": content.truncated]
            case let (_, .issue(.ambiguousAlias(alias, _))):
                throw RemoteAgentControlServiceError.commandRejected("Several workspace roots match \(alias). Ask which root to use.")
            default:
                throw Self.pathUnavailable
            }
        }
        try await manager.validatePrimaryRootSnapshot(snapshot)
        guard !window.isClosing, manager.activeWorkspaceID == workspaceID else {
            throw RemoteWorkspaceVoiceError.workspaceClosed
        }
        return try encode(result)
    }

    private func listChildren(rootID: UUID, directory: String, displayPath: String) async -> [String: Any] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        func isDirectChild(_ path: String) -> Bool {
            guard path.hasPrefix(prefix) else { return false }
            let name = path.dropFirst(prefix.count)
            return !name.isEmpty && !name.contains("/")
        }
        let store = window.workspaceFileContextStore
        let folders = await store.folders(inRoot: rootID).filter { isDirectChild($0.standardizedRelativePath) }
        let files = await store.files(inRoot: rootID).filter { isDirectChild($0.standardizedRelativePath) }
        let entries = folders.map { ["name": $0.name, "kind": "folder"] }
            + files.map { ["name": $0.name, "kind": "file"] }
        return ["path": displayPath, "entries": Array(entries.prefix(75)), "total": entries.count]
    }

    private func encode(_ value: [String: Any]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static var pathUnavailable: RemoteAgentControlServiceError {
        .commandRejected("That path could not be read in this workspace. Check the folder or file name.")
    }
}
