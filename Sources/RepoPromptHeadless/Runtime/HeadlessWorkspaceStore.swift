import Foundation

final class HeadlessWorkspaceStore: @unchecked Sendable {
    private let paths: HeadlessStatePaths
    private let fileManager: FileManager

    init(paths: HeadlessStatePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadWorkspaces() throws -> [HeadlessWorkspaceDocument] {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard fileManager.fileExists(atPath: paths.workspacesDirectory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: paths.workspacesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var documents: [HeadlessWorkspaceDocument] = []
        for file in files where file.pathExtension == "json" {
            guard let workspaceID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                throw HeadlessCommandError(
                    "Headless workspace filename must be a UUID: \(file.lastPathComponent)",
                    exitCode: 2
                )
            }
            let lockFile = paths.workspaceLockFile(for: workspaceID)
            let document = try HeadlessFileLock.withExclusiveLock(
                path: lockFile,
                stateRoot: paths.rootDirectory
            ) {
                try loadWorkspaceUnlocked(file: file, expectedID: workspaceID)
            }
            if let document {
                documents.append(document)
            }
        }
        documents.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return documents
    }

    func loadWorkspace(id: UUID) throws -> HeadlessWorkspaceDocument? {
        try HeadlessFileLock.withExclusiveLock(
            path: paths.workspaceLockFile(for: id),
            stateRoot: paths.rootDirectory
        ) {
            try loadWorkspaceUnlocked(file: workspaceFile(for: id), expectedID: id)
        }
    }

    @discardableResult
    func save(_ workspace: HeadlessWorkspaceDocument) throws -> HeadlessWorkspaceDocument {
        try HeadlessFileLock.withExclusiveLock(
            path: paths.workspaceLockFile(for: workspace.id),
            stateRoot: paths.rootDirectory
        ) {
            try saveUnlocked(workspace)
        }
    }

    func update(id: UUID, _ body: (inout HeadlessWorkspaceDocument) throws -> Void) throws -> HeadlessWorkspaceDocument {
        try HeadlessFileLock.withExclusiveLock(
            path: paths.workspaceLockFile(for: id),
            stateRoot: paths.rootDirectory
        ) {
            guard var workspace = try loadWorkspaceUnlocked(file: workspaceFile(for: id), expectedID: id) else {
                throw HeadlessCommandError("No headless workspace found for id \(id.uuidString).", exitCode: 2)
            }
            try body(&workspace)
            workspace.touch()
            return try saveUnlocked(workspace)
        }
    }

    private func loadWorkspaceUnlocked(file: URL, expectedID: UUID) throws -> HeadlessWorkspaceDocument? {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard let data = try HeadlessStateFileSecurity.readPrivateFileIfPresent(at: file, stateRoot: paths.rootDirectory) else {
            return nil
        }
        var document = try HeadlessJSONFormatting.decoder().decode(HeadlessWorkspaceDocument.self, from: data)
        guard document.schemaVersion == HeadlessWorkspaceDocument.currentSchemaVersion else {
            throw HeadlessCommandError(
                "Unsupported headless workspace schema_version \(document.schemaVersion) in \(file.lastPathComponent); expected \(HeadlessWorkspaceDocument.currentSchemaVersion).",
                exitCode: 2
            )
        }
        guard document.id == expectedID else {
            throw HeadlessCommandError(
                "Headless workspace id \(document.id.uuidString) does not match filename \(expectedID.uuidString).",
                exitCode: 2
            )
        }

        let normalizedSelection = HeadlessSelectionNormalizer.normalized(document.selection)
        if normalizedSelection != document.selection {
            document.selection = normalizedSelection
            try saveUnlocked(document, file: file)
        }
        return document
    }

    @discardableResult
    private func saveUnlocked(
        _ workspace: HeadlessWorkspaceDocument,
        file: URL? = nil
    ) throws -> HeadlessWorkspaceDocument {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        var normalizedWorkspace = workspace
        normalizedWorkspace.selection = HeadlessSelectionNormalizer.normalized(workspace.selection)
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(normalizedWorkspace)
        try HeadlessStateFileSecurity.writePrivateFile(
            data,
            to: file ?? workspaceFile(for: workspace.id),
            stateRoot: paths.rootDirectory,
            fileManager: fileManager
        )
        return normalizedWorkspace
    }

    private func workspaceFile(for id: UUID) -> URL {
        paths.workspacesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
